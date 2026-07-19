"""Local operator recovery for the personal access passphrase.

``initialize`` creates the credential row (generation 1) as the fallback /
operator path behind the mac app's set-passphrase flow. ``reset-passphrase`` is
the only forget-passphrase recovery: it force-rotates the passphrase and bumps
the generation, revoking every existing access key. The passphrase is read from
standard input and never printed or logged.
"""

import argparse
import asyncio
import sys

from fiscal_api.core.access_keys import is_valid_passphrase_length
from fiscal_api.core.config import Settings
from fiscal_api.db.session import create_engine, create_session_factory
from fiscal_api.services.access import AccessService


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Fiscal access passphrase administration")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser(
        "initialize",
        help="Create the access credential from a passphrase read on standard input",
    )
    subparsers.add_parser(
        "reset-passphrase",
        help="Force a new passphrase (read on standard input) and revoke all access keys",
    )
    return parser


async def _initialize(settings: Settings, passphrase: str) -> None:
    engine = create_engine(settings.database_url)
    factory = create_session_factory(engine)
    try:
        async with factory() as session:
            service = AccessService(session, settings)
            if await service.get_credential() is not None:
                raise RuntimeError("An access passphrase is already set; use reset-passphrase")
            minted = await service.initialize(passphrase)
            print(f"credential_generation={minted.credential_generation}")
    finally:
        await engine.dispose()


async def _reset(settings: Settings, passphrase: str) -> None:
    engine = create_engine(settings.database_url)
    factory = create_session_factory(engine)
    try:
        async with factory() as session:
            service = AccessService(session, settings)
            if await service.get_credential() is None:
                raise RuntimeError("No access passphrase is set; use initialize")
            minted = await service.change(passphrase)
            print(f"credential_generation={minted.credential_generation}")
    finally:
        await engine.dispose()


def main() -> None:
    args = _parser().parse_args()
    passphrase = sys.stdin.readline().rstrip("\n")
    if not is_valid_passphrase_length(passphrase):
        raise SystemExit("The passphrase read on standard input must be 8 to 128 characters")
    settings = Settings()
    if settings.token_pepper is None:
        raise SystemExit("FISCAL_TOKEN_PEPPER is required")
    try:
        if args.command == "initialize":
            asyncio.run(_initialize(settings, passphrase))
        else:
            asyncio.run(_reset(settings, passphrase))
    except RuntimeError as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
