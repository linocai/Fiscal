import argparse
import asyncio
import sys

from sqlalchemy import select

from fiscal_api.core.config import Settings
from fiscal_api.core.device_tokens import (
    is_well_formed_database_token,
    token_digest,
    token_fingerprint,
)
from fiscal_api.core.time import utc_now
from fiscal_api.db.models.security import DeviceToken, DeviceTokenRole, DeviceTokenStatus
from fiscal_api.db.session import create_engine, create_session_factory


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Fiscal local device-token administration")
    subparsers = parser.add_subparsers(dest="command", required=True)
    bootstrap = subparsers.add_parser(
        "bootstrap-operator", help="Import an operator token from standard input"
    )
    bootstrap.add_argument("--label", required=True)
    return parser


async def _bootstrap_operator(settings: Settings, label: str, raw_token: str) -> None:
    if settings.token_pepper is None:
        raise RuntimeError("FISCAL_TOKEN_PEPPER is required")
    if not is_well_formed_database_token(raw_token):
        raise RuntimeError("The operator token read from stdin is not a Fiscal device token")
    normalized_label = label.strip()
    if not 1 <= len(normalized_label) <= 80:
        raise RuntimeError("The operator label must contain 1 to 80 characters")
    digest = token_digest(raw_token, settings.token_pepper.get_secret_value())
    engine = create_engine(settings.database_url)
    factory = create_session_factory(engine)
    try:
        async with factory() as session:
            existing = await session.scalar(
                select(DeviceToken.id).where(DeviceToken.token_digest == digest)
            )
            if existing:
                raise RuntimeError("That token is already registered")
            now = utc_now()
            row = DeviceToken(
                label=normalized_label,
                role=DeviceTokenRole.OPERATOR,
                status=DeviceTokenStatus.ACTIVE,
                token_digest=digest,
                fingerprint=token_fingerprint(raw_token),
                pepper_version=settings.token_pepper_version,
                version=1,
                activated_at=now,
                created_at=now,
                updated_at=now,
            )
            session.add(row)
            await session.commit()
            print(f"operator_id={row.id} fingerprint={row.fingerprint}")
    finally:
        await engine.dispose()


def main() -> None:
    args = _parser().parse_args()
    raw_token = sys.stdin.read().strip()
    if not raw_token:
        raise SystemExit("A token must be supplied on standard input")
    try:
        asyncio.run(_bootstrap_operator(Settings(), args.label, raw_token))
    except RuntimeError as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
