from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).parents[1] / "scripts"
DEPLOY = (SCRIPTS / "deploy.sh").read_text(encoding="utf-8")
BOOTSTRAP = (SCRIPTS / "bootstrap-host.sh").read_text(encoding="utf-8")
BOOTSTRAP_PATH = SCRIPTS / "bootstrap-host.sh"
RESTORE_VERIFY = (SCRIPTS / "restore-verify.sh").read_text(encoding="utf-8")
SHADOW_WRAPPER = (SCRIPTS / "p22-shadow-wrapper.sh").read_text(encoding="utf-8")


class DeployReleasePermissionsTests(unittest.TestCase):
    def test_release_access_dry_run_is_explicit_and_has_no_apply_side_effects(self) -> None:
        result = subprocess.run(
            ["bash", str(BOOTSTRAP_PATH), "--release-access"],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dry-run release access bootstrap", result.stderr)
        self.assertIn("no packages, users, files or services were changed", result.stderr)

    def test_dedicated_release_group_excludes_environment_group(self) -> None:
        self.assertIn("groupadd --system fiscal_release", BOOTSTRAP)
        self.assertIn("usermod --append --groups fiscal_release", BOOTSTRAP)
        self.assertNotIn("usermod --append --groups fiscal ", BOOTSTRAP)
        self.assertIn("fiscal_release group is missing", DEPLOY)
        self.assertIn("must belong to fiscal_release", DEPLOY)

    def test_release_access_branch_exits_before_full_host_bootstrap(self) -> None:
        release_access_branch = BOOTSTRAP.index('if [[ "$release_access" == true ]]; then')
        full_bootstrap = BOOTSTRAP.index('[[ "$uv_version" =~')
        self.assertLess(release_access_branch, full_bootstrap)
        self.assertIn('die "/etc/fiscal/fiscal.env metadata changed unexpectedly"', BOOTSTRAP)

    def test_restore_verify_uses_migrator_for_release_alembic_only(self) -> None:
        expected_head = RESTORE_VERIFY.index('expected_head="$(')
        expected_head_block = RESTORE_VERIFY[expected_head : RESTORE_VERIFY.index('[[ -n "$actual_head"', expected_head)]

        self.assertIn("run_as_migrator env", expected_head_block)
        self.assertNotIn("run_as_postgres env", expected_head_block)
        self.assertIn("run_as_postgres pg_restore", RESTORE_VERIFY)

    def test_p22_shadow_wrapper_fixes_workspace_and_cwd_contract(self) -> None:
        self.assertIn('install -d -o root -g fiscal_migrator -m 0710 "$evidence_parent"', SHADOW_WRAPPER)
        self.assertIn('install -d -o fiscal_migrator -g fiscal_migrator -m 0700 "$workspace"', SHADOW_WRAPPER)
        self.assertIn('runuser --user=fiscal_migrator -- test -w "$workspace"', SHADOW_WRAPPER)
        self.assertIn('cd "$2/backend"', SHADOW_WRAPPER)
        self.assertIn('rm -f -- "$source_env" "$target_env" "$password_file"', SHADOW_WRAPPER)
        self.assertIn('--source-preflight', SHADOW_WRAPPER)
        self.assertIn('P22 source/principal preflight passed; no target database was used', SHADOW_WRAPPER)
        self.assertIn('psql --dbname=postgres', SHADOW_WRAPPER)

    def test_p22_shadow_target_normalization_keeps_identifier_whitelist(self) -> None:
        self.assertIn("tr '[:upper:]' '[:lower:]'", SHADOW_WRAPPER)
        self.assertIn('^fiscal_p22_shadow_[a-z0-9_]+$', SHADOW_WRAPPER)

    def test_p22_shadow_archive_wrapper_keeps_credentials_off_argv_and_cleans_them(self) -> None:
        self.assertIn("--archive-export|--archive-dry-run|--archive-apply", SHADOW_WRAPPER)
        self.assertIn('archive output already exists and will not be overwritten', SHADOW_WRAPPER)
        self.assertIn('os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600', SHADOW_WRAPPER)
        self.assertIn('os.environ["FISCAL_MIGRATION_DATABASE_URL"]', SHADOW_WRAPPER)
        self.assertNotIn(' - "$FISCAL_MIGRATION_DATABASE_URL" ', SHADOW_WRAPPER)
        self.assertIn('password_file="$workspace/archive-password"', SHADOW_WRAPPER)
        self.assertIn('printf \'%s\\n\' "$archive_password" >"$password_file"', SHADOW_WRAPPER)
        self.assertIn('chmod 0600 "$password_file"', SHADOW_WRAPPER)
        self.assertIn('rm -f -- "$source_env" "$target_env" "$password_file"', SHADOW_WRAPPER)
        self.assertIn('exec "$python_bin" -m "$archive_module" "$@" < "$archive_password"', SHADOW_WRAPPER)

    def test_p22_shadow_controlled_env_overrides_a_hostile_inherited_dsn(self) -> None:
        controlled_dsn = "postgresql+asyncpg://fiscal_migrator@/fiscal_p22_shadow_test"
        with tempfile.TemporaryDirectory() as temporary_directory:
            controlled_env = Path(temporary_directory) / "target.env"
            controlled_env.write_text(f"FISCAL_DATABASE_URL={controlled_dsn}\n", encoding="utf-8")
            result = subprocess.run(
                [
                    "bash",
                    "-ceu",
                    'set -a; . "$1"; set +a; printf "%s" "$FISCAL_DATABASE_URL"',
                    "_",
                    str(controlled_env),
                ],
                check=False,
                capture_output=True,
                env={**os.environ, "FISCAL_DATABASE_URL": "postgresql://hostile/service"},
                text=True,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, controlled_dsn)
        self.assertIn('unset FISCAL_DATABASE_URL FISCAL_MIGRATION_DATABASE_URL', SHADOW_WRAPPER)
        self.assertIn('set -a; . "$1"; set +a', SHADOW_WRAPPER)
        self.assertIn('set -a; . "$database_env"; set +a', SHADOW_WRAPPER)

    def test_p22_shadow_archive_modes_keep_source_and_target_contracts_separate(self) -> None:
        self.assertIn('if [[ "$source_preflight" == true || "$archive_action" == "export" ]]; then', SHADOW_WRAPPER)
        self.assertIn('if source_database != "fiscal":', SHADOW_WRAPPER)
        self.assertIn('target must be an explicitly scoped fiscal_p22_shadow database', SHADOW_WRAPPER)
        self.assertIn('run_archive "$source_env" fiscal_api.cli.archive_export "$archive_path"', SHADOW_WRAPPER)
        self.assertIn('run_archive "$target_env" fiscal_api.cli.archive "$archive_path" --dry-run', SHADOW_WRAPPER)
        self.assertIn('run_archive "$target_env" fiscal_api.cli.archive "$archive_path" --apply --confirm-empty-target', SHADOW_WRAPPER)
        self.assertIn("--archive-roundtrip", SHADOW_WRAPPER)
        self.assertIn('"$archive_action" != "roundtrip" || ! -e "$archive_path"', SHADOW_WRAPPER)
        self.assertIn('"$archive_action" == "roundtrip" || -f "$archive_path"', SHADOW_WRAPPER)
        roundtrip = SHADOW_WRAPPER.index("  roundtrip)")
        roundtrip_block = SHADOW_WRAPPER[roundtrip : SHADOW_WRAPPER.index("    ;;", roundtrip)]
        self.assertLess(roundtrip_block.index("archive_export"), roundtrip_block.index("--dry-run"))
        self.assertLess(roundtrip_block.index("--dry-run"), roundtrip_block.index("--apply"))

    def test_p22_shadow_provisioning_rejects_existing_and_proves_migrator_control(self) -> None:
        self.assertIn("--provision-target", SHADOW_WRAPPER)
        self.assertIn('target database already exists and will not be reused', SHADOW_WRAPPER)
        self.assertIn('createdb --template=template0 --owner=fiscal_migrator "$target_database"', SHADOW_WRAPPER)
        self.assertIn('fresh target database owner is not fiscal_migrator', SHADOW_WRAPPER)
        self.assertIn("has_schema_privilege('fiscal_migrator', 'public', 'CREATE')", SHADOW_WRAPPER)
        self.assertIn('local probe_table="p22_provision_probe_$$"', SHADOW_WRAPPER)
        self.assertIn('CREATE TABLE $probe_table (id integer); DROP TABLE $probe_table', SHADOW_WRAPPER)
        self.assertIn('exec "$3" --config alembic.ini upgrade head', SHADOW_WRAPPER)

    def test_release_tree_is_group_readable_before_migrator_preflight(self) -> None:
        ownership = DEPLOY.index('chown -R root:fiscal_release "$temporary_release"')
        directories = DEPLOY.index('find "$temporary_release" -type d -exec chmod 0750 {} +')
        executables = DEPLOY.index('find "$temporary_release" -type f -perm /111 -exec chmod 0750 {} +')
        files = DEPLOY.index('find "$temporary_release" -type f ! -perm /111 -exec chmod 0640 {} +')
        release_move = DEPLOY.index('mv -- "$temporary_release" "$release"')
        readable_probe = DEPLOY.index('run_as_migrator test -r "$release/backend/.venv/bin/alembic"')
        import_probe = DEPLOY.index('run_as_migrator "$release/backend/.venv/bin/python" -c \'import alembic\'')
        migration = DEPLOY.index('run_as_migrator env')

        self.assertLess(ownership, directories)
        self.assertLess(directories, executables)
        self.assertLess(executables, files)
        self.assertLess(files, release_move)
        self.assertLess(release_move, readable_probe)
        self.assertLess(readable_probe, import_probe)
        self.assertLess(import_probe, migration)


if __name__ == "__main__":
    unittest.main()
