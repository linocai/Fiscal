from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).parents[1] / "scripts"
DEPLOY = (SCRIPTS / "deploy.sh").read_text(encoding="utf-8")
BOOTSTRAP = (SCRIPTS / "bootstrap-host.sh").read_text(encoding="utf-8")
BOOTSTRAP_PATH = SCRIPTS / "bootstrap-host.sh"
RESTORE_VERIFY = (SCRIPTS / "restore-verify.sh").read_text(encoding="utf-8")


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
