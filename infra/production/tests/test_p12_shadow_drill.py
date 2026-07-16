from __future__ import annotations

import os
import subprocess
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "p12-shadow-drill.sh"


class ShadowDrillShellTests(unittest.TestCase):
    def run_script(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        environment = {"PATH": os.environ["PATH"]}
        return subprocess.run(
            ["bash", str(SCRIPT), *arguments],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

    def test_protected_database_names_are_rejected_before_apply(self) -> None:
        for database in ("fiscal", "LinoFinance", "postgres", "template0", "template1"):
            with self.subTest(database=database):
                result = self.run_script("--target-database", database, "--apply")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("protected database name", result.stderr)
                self.assertNotIn("missing baseline", result.stderr)

    def test_target_name_must_be_explicitly_shadow_scoped(self) -> None:
        result = self.run_script("--target-database", "fiscal_copy")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must contain 'shadow' or 'drill'", result.stderr)

    def test_dry_run_needs_no_credentials_and_changes_nothing(self) -> None:
        result = self.run_script("--target-database", "fiscal_p12_shadow_20260716")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("P12 shadow drill plan", result.stderr)
        self.assertIn("no database or file was changed", result.stderr)

    def test_script_never_drops_or_embeds_a_database_url(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("dropdb", source)
        self.assertNotIn("DROP DATABASE", source)
        self.assertNotRegex(source, r"postgres(?:ql)?://")
        self.assertIn("umask 077", source)
        self.assertIn("chmod 0600", source)
        self.assertIn("prior evidence is never overwritten", source)
        self.assertIn('pg_run "$FISCAL_SHADOW_TARGET_PG_URL"', source)
        self.assertIn('export FISCAL_DATABASE_URL="$FISCAL_SHADOW_TARGET_DATABASE_URL"', source)
        self.assertNotIn('--dbname="$FISCAL_SHADOW', source)


if __name__ == "__main__":
    unittest.main()
