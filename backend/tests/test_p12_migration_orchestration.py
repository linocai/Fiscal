from datetime import date, datetime

import pytest

from fiscal_api.core.time import UTC
from fiscal_api.legacy_migration.apply import (
    AccountImport,
    ClaimImport,
    LegacyManifest,
    ReceiptImport,
    SkippedImport,
    SourceIdentity,
    TransactionImport,
)
from fiscal_api.legacy_migration.orchestration import (
    PRODUCTION_CONFIRM_ENV,
    _expected_monthly,
    _expected_transaction_aggregates,
    _require_production_database,
    _require_production_target_state,
    _require_shadow_database,
    resolved_plan,
    target_dsn,
)
from fiscal_api.legacy_migration.planning import _parser


def _source(object_type: str, object_id: str) -> SourceIdentity:
    return SourceIdentity(object_type, object_id, "a" * 64)


def _manifest() -> LegacyManifest:
    return LegacyManifest(
        source_database_fingerprint="b" * 64,
        accounts=(
            AccountImport(_source("accounts", "debit-1"), "借记卡", "debit", 0),
            AccountImport(
                _source("accounts", "credit-1"),
                "信用卡",
                "credit",
                100,
                credit_limit_minor=10_000,
                statement_day=1,
                due_day=8,
                opening_balance_as_of_date=date(2026, 5, 15),
                opening_due_date=date(2026, 6, 8),
            ),
        ),
        transactions=(
            TransactionImport(
                _source("financial_entries", "income-1"),
                "income",
                1_000,
                datetime(2026, 5, 16, 4, tzinfo=UTC),
                "工资",
                "debit-1",
            ),
            TransactionImport(
                _source("financial_entries", "expense-1"),
                "credit_purchase",
                300,
                datetime(2026, 5, 17, 4, tzinfo=UTC),
                "消费",
                "credit-1",
            ),
            TransactionImport(
                _source("financial_entries", "repay-1"),
                "repayment",
                200,
                datetime(2026, 6, 1, 4, tzinfo=UTC),
                "还款",
                "debit-1",
                destination_account_source_id="credit-1",
                credit_cycle_selector="opening",
            ),
        ),
        claims=(
            ClaimImport(
                _source("reimbursement_claims", "claim-1"),
                "垫付",
                "expense-1",
                50,
                "公司",
            ),
        ),
        receipts=(
            ReceiptImport(
                _source("reimbursement_receipts", "claim-1"),
                "claim-1",
                "debit-1",
                50,
                datetime(2026, 6, 2, 4, tzinfo=UTC),
                "公司报销到账",
                "suppressed-income",
            ),
        ),
        skipped=(SkippedImport(_source("financial_entries", "voided-1"), "voided"),),
    )


def test_cli_exposes_shadow_apply_and_reconcile_without_dsn_arguments() -> None:
    parser = _parser()
    assert parser.parse_args(["apply"]).command == "apply"
    assert parser.parse_args(["reconcile"]).command == "reconcile"
    assert parser.parse_args(["production-apply"]).command == "production-apply"
    assert parser.parse_args(["production-reconcile"]).command == "production-reconcile"
    assert all(action.dest != "database_url" for action in parser._actions)
    with pytest.raises(RuntimeError, match="FISCAL_DATABASE_URL must be set"):
        target_dsn({})


def test_resolved_plan_and_expected_reports_cover_create_skip_and_months() -> None:
    manifest = _manifest()
    plan = resolved_plan(manifest)
    assert plan["ready_for_apply"] is True
    assert plan["create_summary"] == {
        "accounts": 2,
        "categories": 0,
        "transactions": 3,
        "reimbursement_claims": 1,
        "reimbursement_receipts": 1,
    }
    assert plan["skip_summary"] == {"voided": 1}

    aggregates = _expected_transaction_aggregates(manifest)
    assert aggregates["credit_purchase"].amount_minor == 300
    assert aggregates["reimbursement_receipt"].count == 1
    monthly = _expected_monthly(manifest)
    assert monthly["2026-05"].income_minor == 1_000
    assert monthly["2026-05"].spending_minor == 300
    assert monthly["2026-05"].cash_inflow_minor == 1_000
    assert monthly["2026-06"].cash_outflow_minor == 200
    assert monthly["2026-06"].cash_inflow_minor == 50
    assert monthly["2026-06"].reimbursement_received_minor == 50


class _DatabaseSession:
    def __init__(self, database: str) -> None:
        self.database = database

    async def scalar(self, _statement: object) -> str:
        return self.database


async def test_apply_and_reconcile_are_restricted_to_shadow_database_names() -> None:
    assert await _require_shadow_database(_DatabaseSession("fiscal_p12_shadow")) == (
        "fiscal_p12_shadow"
    )
    assert await _require_shadow_database(_DatabaseSession("fiscal_drill_20260716")) == (
        "fiscal_drill_20260716"
    )
    with pytest.raises(RuntimeError, match="production apply is not enabled"):
        await _require_shadow_database(_DatabaseSession("fiscal"))


class _ProductionSession:
    def __init__(self, database: str, other_clients: int = 0) -> None:
        self.values = iter((database, other_clients))

    async def scalar(self, _statement: object) -> str | int:
        return next(self.values)


async def test_production_requires_exact_database_confirmation_and_exclusive_window() -> None:
    manifest = _manifest()
    confirmation = {PRODUCTION_CONFIRM_ENV: f"fiscal:{manifest.source_database_fingerprint}"}
    assert (
        await _require_production_database(_ProductionSession("fiscal"), manifest, confirmation)
        == "fiscal"
    )

    with pytest.raises(RuntimeError, match="exact target database fiscal"):
        await _require_production_database(
            _ProductionSession("fiscal_shadow"), manifest, confirmation
        )
    with pytest.raises(RuntimeError, match=PRODUCTION_CONFIRM_ENV):
        await _require_production_database(_ProductionSession("fiscal"), manifest, {})
    with pytest.raises(RuntimeError, match="exclusive write window"):
        await _require_production_database(
            _ProductionSession("fiscal", other_clients=1), manifest, confirmation
        )


async def test_production_target_must_be_pristine_or_same_source_replay() -> None:
    manifest = _manifest()
    await _require_production_target_state(_ProductionSession("0", 0), manifest)

    with pytest.raises(RuntimeError, match="business tables are not empty"):
        await _require_production_target_state(_ProductionSession("0", 1), manifest)

    await _require_production_target_state(_ProductionSession("3", 0), manifest)
    with pytest.raises(RuntimeError, match="different source"):
        await _require_production_target_state(_ProductionSession("3", 1), manifest)
