"""Local, two-step Fiscal Archive restore operator tool.

Passwords are read from standard input. The target database is read from the
normal Fiscal environment, never an argv value. ``--apply`` refuses any target
that contains Fiscal data; cutover remains an operator action outside this CLI.
"""

import argparse
import asyncio
import json
import sys
from pathlib import Path

from fiscal_api.core.config import Settings
from fiscal_api.db.session import create_engine
from fiscal_api.services.archive import ArchiveError, ArchiveService


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Inspect or restore a Fiscal Archive v1 file")
    parser.add_argument("archive", type=Path)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--dry-run", action="store_true")
    action.add_argument("--apply", action="store_true")
    parser.add_argument(
        "--confirm-empty-target",
        action="store_true",
        help="required with --apply after reviewing a successful dry run",
    )
    return parser


async def _run(args: argparse.Namespace, password: str) -> None:
    manifest, payload = ArchiveService.open(args.archive.read_bytes(), password=password)
    report = ArchiveService.dry_run_report(manifest, payload)
    print(json.dumps(report, sort_keys=True, ensure_ascii=False))
    if not args.apply:
        return
    if not args.confirm_empty_target:
        raise ArchiveError("--apply requires --confirm-empty-target after a successful dry run")
    settings = Settings()
    engine = create_engine(settings.database_url)
    try:
        async with engine.begin() as connection:
            await ArchiveService.restore_empty_target(
                connection, manifest=manifest, payload=payload
            )
    finally:
        await engine.dispose()
    print("restore_complete=true")


def main() -> None:
    args = _parser().parse_args()
    password = sys.stdin.readline().rstrip("\n")
    if not 12 <= len(password) <= 128:
        raise SystemExit("archive password read from standard input must be 12 to 128 characters")
    try:
        asyncio.run(_run(args, password))
    except (OSError, ArchiveError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
