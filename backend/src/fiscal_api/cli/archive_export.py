"""Local Fiscal Archive v1 export operator tool.

The password is read from standard input and the database URL only from the
normal Fiscal environment. The output path is intentionally explicit and is
created exclusively; an existing archive is never overwritten.
"""

import argparse
import asyncio
import sys
from pathlib import Path

from fiscal_api.core.config import Settings
from fiscal_api.db.session import create_engine, create_session_factory
from fiscal_api.services.archive import ArchiveService


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Export an encrypted Fiscal Archive v1 file")
    parser.add_argument("output", type=Path, help="new .far output path; must not already exist")
    parser.add_argument(
        "--include-ai-raw",
        action="store_true",
        help="include AI raw input in the encrypted payload (off by default)",
    )
    return parser


async def _run(args: argparse.Namespace, password: str) -> None:
    engine = create_engine(Settings().database_url)
    try:
        factory = create_session_factory(engine)
        async with factory() as session:
            archive, _manifest = await ArchiveService(session).export(
                password=password, include_ai_raw=args.include_ai_raw
            )
        with args.output.open("xb") as output:
            output.write(archive)
    finally:
        await engine.dispose()
    print(f"archive_written={args.output}")


def main() -> None:
    args = _parser().parse_args()
    password = sys.stdin.readline().rstrip("\n")
    if not 12 <= len(password) <= 128:
        raise SystemExit("archive password read from standard input must be 12 to 128 characters")
    try:
        asyncio.run(_run(args, password))
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
