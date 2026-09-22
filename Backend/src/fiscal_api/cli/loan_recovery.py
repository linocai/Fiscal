"""Recover a user-confirmed loan; dry-run by default, never infer balances."""

import argparse
import asyncio
import json
from pathlib import Path
from uuid import UUID

from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from fiscal_api.core.config import get_settings
from fiscal_api.db.session import FiscalAsyncSession
from fiscal_api.services.loan_recovery import LoanRecoveryRequest, recover_loan


async def run(args: argparse.Namespace) -> None:
    request = LoanRecoveryRequest.model_validate_json(
        await asyncio.to_thread(Path(args.request).read_text)
    )
    engine = create_async_engine(get_settings().database_url)
    try:
        async with async_sessionmaker(
            engine, class_=FiscalAsyncSession, expire_on_commit=False
        )() as session:
            session.info["data_revision_scopes"] = (
                "accounts",
                "ledger",
                "credit",
                "cash_flow",
                "reports",
            )
            try:
                result = await recover_loan(session, request, UUID(args.key))
                # Execute all deferred financial guards during dry-run, too.
                from sqlalchemy import text

                await session.execute(text("SET CONSTRAINTS ALL IMMEDIATE"))
                if args.apply:
                    await session.commit()
                else:
                    await session.rollback()
                result["applied"] = args.apply
                print(json.dumps(result, indent=2))
            except Exception:
                await session.rollback()
                raise
    finally:
        await engine.dispose()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--apply", action="store_true")
    asyncio.run(run(parser.parse_args()))


if __name__ == "__main__":
    main()
