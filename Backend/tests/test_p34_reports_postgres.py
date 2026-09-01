from __future__ import annotations

import asyncio
import csv
import re
from datetime import UTC, date, datetime
from decimal import Decimal
from io import StringIO
from os import environ
from pathlib import Path
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import create_async_engine

from fiscal_api.api.p34_schemas import (
    MAX_REPORT_YEAR,
    MIN_REPORT_YEAR,
    SUPPORTED_REPORT_YEAR_RANGE,
    ReportPeriodKind,
)
from fiscal_api.core.config import Settings, get_settings
from fiscal_api.core.time import BUSINESS_TIMEZONE
from fiscal_api.db.session import create_engine, create_session_factory
from fiscal_api.main import create_app
from fiscal_api.services.archive import ArchiveService
from fiscal_api.services.reporting import ReportingService

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


def _app() -> tuple[object, dict[str, str]]:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    return (
        create_app(
            settings=Settings(environment="test", database_url=TEST_DATABASE_URL),
            readiness_check=ready,
        ),
        {"Authorization": "Bearer p34-token"},
    )


def _alembic_config() -> Config:
    return Config(str(Path(__file__).parents[1] / "alembic.ini"))


def _fresh_database_url(name: str) -> str:
    assert TEST_DATABASE_URL is not None
    return make_url(TEST_DATABASE_URL).set(database=name).render_as_string(hide_password=False)


async def _create_database(name: str) -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(
        make_url(TEST_DATABASE_URL).set(database="postgres").render_as_string(hide_password=False),
        isolation_level="AUTOCOMMIT",
    )
    try:
        async with engine.connect() as connection:
            await connection.execute(text(f'CREATE DATABASE "{name}"'))
    finally:
        await engine.dispose()


async def _drop_database(name: str) -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(
        make_url(TEST_DATABASE_URL).set(database="postgres").render_as_string(hide_password=False),
        isolation_level="AUTOCOMMIT",
    )
    try:
        async with engine.connect() as connection:
            await connection.execute(text(f'DROP DATABASE IF EXISTS "{name}"'))
    finally:
        await engine.dispose()


def _account(client: TestClient, auth: dict[str, str], *, name: str) -> dict[str, object]:
    response = client.post(
        "/api/v1/accounts",
        headers=auth,
        json={"name": name, "kind": "debit", "opening_balance_minor": 10_000},
    )
    assert response.status_code == 201, response.text
    return response.json()


def _category(client: TestClient, auth: dict[str, str]) -> dict[str, object]:
    response = client.post(
        "/api/v1/categories",
        headers=auth,
        json={
            "name": "P34 餐饮",
            "direction": "expense",
            "icon": "fork.knife",
            "color_hex": "#123456",
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def _transaction(
    client: TestClient,
    auth: dict[str, str],
    payload: dict[str, object],
) -> dict[str, object]:
    response = client.post(
        "/api/v1/transactions",
        headers={**auth, "Idempotency-Key": str(uuid4())},
        json=payload,
    )
    assert response.status_code == 201, response.text
    return response.json()


def _assert_period_range_error(
    client: TestClient, auth: dict[str, str], path: str, *, code: str
) -> None:
    response = client.get(path, headers=auth)
    assert response.status_code == 422, response.text
    assert response.json()["error"]["code"] == code
    assert response.json()["error"]["details"] == {
        "minimum_year": MIN_REPORT_YEAR,
        "maximum_year": MAX_REPORT_YEAR,
        "supported_year_range": SUPPORTED_REPORT_YEAR_RANGE,
    }


def test_p34_report_year_range_is_shanghai_utc_safe() -> None:
    """Derive the lower public bound from zoneinfo's real historical offset."""
    with pytest.raises(OverflowError):
        datetime(1, 1, 1, tzinfo=BUSINESS_TIMEZONE).astimezone(UTC)
    assert MIN_REPORT_YEAR == 2
    start, end = ReportingService._period_bounds(ReportPeriodKind.YEAR, f"{MIN_REPORT_YEAR:04d}")
    start_utc, end_utc = ReportingService._bounds(start, end)
    assert start == date(MIN_REPORT_YEAR, 1, 1)
    assert end == date(MIN_REPORT_YEAR, 12, 31)
    assert start_utc < end_utc


async def _record_reimbursement_revision_at(
    *,
    claim_id: str,
    claim_version: int,
    claim_at: datetime,
    receipt_id: str | None = None,
    receipt_version: int | None = None,
    receipt_at: datetime | None = None,
    transaction_id: str | None = None,
    transaction_version: int | None = None,
    transaction_at: datetime | None = None,
) -> None:
    """Place immutable formal records on a deterministic audit timeline."""
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    try:
        async with engine.begin() as connection:
            await connection.execute(
                text(
                    "UPDATE reimbursement_claim_revisions SET created_at = :at "
                    "WHERE claim_id = :claim_id AND version = :version"
                ),
                {"at": claim_at, "claim_id": claim_id, "version": claim_version},
            )
            if receipt_id is not None:
                assert receipt_version is not None and receipt_at is not None
                await connection.execute(
                    text(
                        "UPDATE reimbursement_receipt_revisions SET created_at = :at "
                        "WHERE receipt_id = :receipt_id AND version = :version"
                    ),
                    {
                        "at": receipt_at,
                        "receipt_id": receipt_id,
                        "version": receipt_version,
                    },
                )
            if transaction_id is not None:
                assert transaction_version is not None and transaction_at is not None
                await connection.execute(
                    text(
                        "UPDATE transaction_revisions SET created_at = :at "
                        "WHERE transaction_id = :transaction_id AND version = :version"
                    ),
                    {
                        "at": transaction_at,
                        "transaction_id": transaction_id,
                        "version": transaction_version,
                    },
                )
    finally:
        await engine.dispose()


def _post_receipt(
    client: TestClient,
    auth: dict[str, str],
    *,
    claim: dict[str, object],
    amount_minor: int,
    received_at: str,
    destination_account_id: str,
) -> dict[str, object]:
    draft = {
        "expected_claim_version": claim["version"],
        "party_id": claim["parties"][0]["id"],
        "amount_minor": amount_minor,
        "received_at": received_at,
        "destination_account_id": destination_account_id,
        "title": "P34 historical reimbursement receipt",
    }
    preview = client.post(
        f"/api/v1/reimbursement-claims/{claim['id']}/receipt-preview",
        headers=auth,
        json=draft,
    )
    assert preview.status_code == 200, preview.text
    receipt = client.post(
        f"/api/v1/reimbursement-claims/{claim['id']}/receipts",
        headers={**auth, "Idempotency-Key": str(uuid4())},
        json={**draft, "preview_token": preview.json()["preview_token"]},
    )
    assert receipt.status_code == 201, receipt.text
    return receipt.json()


def test_p34_month_year_drilldown_and_exports_share_one_ledger_contract() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        cash = _account(client, auth, name="P34 日常卡")
        destination = _account(client, auth, name="P34 储蓄卡")
        category = _category(client, auth)
        _transaction(
            client,
            auth,
            {
                "kind": "income",
                "amount_minor": 2_000,
                "occurred_at": "2024-02-01T00:00:00+08:00",
                "title": "工资",
                "account_id": cash["id"],
            },
        )
        expense = _transaction(
            client,
            auth,
            {
                "kind": "expense",
                "amount_minor": 1_200,
                "occurred_at": "2024-02-29T23:59:59+08:00",
                "title": "=provider original should not export",
                "note": "4111-1111-1111-1111 secret",
                "account_id": cash["id"],
                "category_id": category["id"],
            },
        )
        _transaction(
            client,
            auth,
            {
                "kind": "transfer",
                "amount_minor": 500,
                "occurred_at": "2024-02-15T12:00:00+08:00",
                "title": "内部转账",
                "account_id": cash["id"],
                "destination_account_id": destination["id"],
            },
        )

        monthly = client.get("/api/v1/reports/monthly/2024-02", headers=auth)
        assert monthly.status_code == 200, monthly.text
        report = monthly.json()
        assert report["meta"]["period"] == "2024-02"
        assert report["meta"]["date_to"] == "2024-02-29"
        assert report["meta"]["timezone"] == "Asia/Shanghai"
        assert report["summary"]["income_minor"] == 2_000
        assert report["summary"]["gross_consumption_minor"] == 1_200
        assert report["summary"]["net_consumption_minor"] == 1_200
        assert report["summary"]["cash_inflow_minor"] == 2_000
        assert report["summary"]["cash_outflow_minor"] == 1_200
        assert report["summary"]["cash_net_minor"] == 800
        assert report["summary"]["internal_transfer_inflow_minor"] == 500
        assert report["summary"]["internal_transfer_outflow_minor"] == 500
        assert sum(row["net_consumption_minor"] for row in report["categories"]) == 1_200
        for year in range(MIN_REPORT_YEAR):
            monthly_period = f"{year:04d}-01"
            yearly_period = f"{year:04d}"
            for suffix in ("", "/export.csv", "/export.pdf"):
                _assert_period_range_error(
                    client,
                    auth,
                    f"/api/v1/reports/monthly/{monthly_period}{suffix}",
                    code="invalid_report_month",
                )
                _assert_period_range_error(
                    client,
                    auth,
                    f"/api/v1/reports/yearly/{yearly_period}{suffix}",
                    code="invalid_report_year",
                )
            _assert_period_range_error(
                client,
                auth,
                "/api/v1/reports/period-drill-down?period_kind=month"
                f"&period={monthly_period}&expected_data_revision=0",
                code="invalid_report_month",
            )
            _assert_period_range_error(
                client,
                auth,
                "/api/v1/reports/period-drill-down?period_kind=year"
                f"&period={yearly_period}&expected_data_revision=0",
                code="invalid_report_year",
            )
        _assert_period_range_error(
            client,
            auth,
            "/api/v1/reports/monthly/9999-12/export.pdf",
            code="invalid_report_month",
        )
        _assert_period_range_error(
            client,
            auth,
            "/api/v1/reports/yearly/9999/export.csv",
            code="invalid_report_year",
        )
        _assert_period_range_error(
            client,
            auth,
            "/api/v1/reports/period-drill-down?period_kind=year&period=9999"
            "&expected_data_revision=0",
            code="invalid_report_year",
        )
        minimum_month = client.get(
            f"/api/v1/reports/monthly/{MIN_REPORT_YEAR:04d}-01", headers=auth
        )
        minimum_year = client.get(f"/api/v1/reports/yearly/{MIN_REPORT_YEAR:04d}", headers=auth)
        assert minimum_month.status_code == minimum_year.status_code == 200
        assert minimum_month.json()["meta"]["date_from"] == f"{MIN_REPORT_YEAR:04d}-01-01"
        assert minimum_year.json()["meta"]["date_to"] == f"{MIN_REPORT_YEAR:04d}-12-31"
        assert client.get("/api/v1/reports/monthly/9998-12", headers=auth).status_code == 200
        assert client.get("/api/v1/reports/yearly/9998", headers=auth).status_code == 200

        annual = client.get("/api/v1/reports/yearly/2024", headers=auth)
        assert annual.status_code == 200, annual.text
        assert annual.json()["summary"] == report["summary"]

        csv_export = client.get("/api/v1/reports/monthly/2024-02/export.csv", headers=auth)
        assert csv_export.status_code == 200, csv_export.text
        assert csv_export.headers["content-type"].startswith("text/csv")
        assert csv_export.headers["cache-control"] == "no-store"
        assert csv_export.content.startswith(b"\xef\xbb\xbf")
        assert "分类,净消费".encode() in csv_export.content
        assert b"provider original" not in csv_export.content
        assert b"4111-1111" not in csv_export.content
        csv_rows = list(csv.DictReader(StringIO(csv_export.content.decode("utf-8-sig"))))
        assert (
            sum(
                int(Decimal(row["金额（元）"]) * 100)
                for row in csv_rows
                if row["分类"] == "分类" and row["项目"] == "净消费"
            )
            == report["summary"]["net_consumption_minor"]
        )

        pdf_export = client.get("/api/v1/reports/monthly/2024-02/export.pdf", headers=auth)
        assert pdf_export.status_code == 200, pdf_export.text
        assert pdf_export.headers["content-type"] == "application/pdf"
        assert pdf_export.content.startswith(b"%PDF-1.4")
        assert b"provider original" not in pdf_export.content
        assert b"4111-1111" not in pdf_export.content
        assert b"startxref" in pdf_export.content and b"STSong-Light" in pdf_export.content
        pdf_text = "\n".join(
            bytes.fromhex(chunk.decode("ascii")).decode("utf-16-be")
            for chunk in re.findall(rb"<([0-9A-F]+)> Tj", pdf_export.content)
        )
        assert "净消费：¥12.00" in pdf_text

        revision = report["meta"]["data_revision"]
        exports = (
            ("/api/v1/reports/monthly/2024-02/export.csv", "text/csv", "csv", "2024-02"),
            ("/api/v1/reports/monthly/2024-02/export.pdf", "application/pdf", "pdf", "2024-02"),
            ("/api/v1/reports/yearly/2024/export.csv", "text/csv", "csv", "2024"),
            ("/api/v1/reports/yearly/2024/export.pdf", "application/pdf", "pdf", "2024"),
        )
        for path, content_type, extension, expected_period in exports:
            # Omission remains compatible for existing callers, but the server
            # still declares the revision of the one report it actually rendered.
            legacy = client.get(path, headers=auth)
            assert legacy.status_code == 200, legacy.text
            assert legacy.headers["x-fiscal-data-revision"] == str(revision)

            bound = client.get(f"{path}?expected_data_revision={revision}", headers=auth)
            assert bound.status_code == 200, bound.text
            assert bound.headers["content-type"].startswith(content_type)
            assert bound.headers["cache-control"] == "no-store"
            assert bound.headers["x-content-type-options"] == "nosniff"
            assert bound.headers["x-fiscal-data-revision"] == str(revision)
            assert (
                f'Fiscal-report-{expected_period}.{extension}"'
                in bound.headers["content-disposition"]
            )
            assert f"-r{revision}" not in bound.headers["content-disposition"]
            if extension == "csv":
                exported_text = bound.content.decode("utf-8-sig")
                assert "分类,项目,对象,金额（元）,数量,说明" in exported_text
                for internal in (
                    "data_revision",
                    "report_schema_version",
                    "stable_id",
                    "value_minor",
                ):
                    assert internal not in exported_text
            else:
                exported_pdf_text = "\n".join(
                    bytes.fromhex(chunk.decode("ascii")).decode("utf-16-be")
                    for chunk in re.findall(rb"<([0-9A-F]+)> Tj", bound.content)
                )
                assert "口径：上海时间 · 人民币" in exported_pdf_text
                assert "revision" not in exported_pdf_text

        drill = client.get(
            "/api/v1/reports/period-drill-down?period_kind=month&period=2024-02"
            f"&expected_data_revision={revision}&limit=1",
            headers=auth,
        )
        assert drill.status_code == 200, drill.text
        assert drill.json()["items"][0]["transaction_id"] in {expense["id"]}
        cursor = drill.json()["next_cursor"]
        assert cursor is not None
        continued = client.get(
            "/api/v1/reports/period-drill-down?period_kind=month&period=2024-02"
            f"&expected_data_revision={revision}&limit=1&cursor={cursor}",
            headers=auth,
        )
        assert continued.status_code == 200, continued.text
        assert (
            continued.json()["items"][0]["transaction_id"]
            != drill.json()["items"][0]["transaction_id"]
        )
        tampered = client.get(
            "/api/v1/reports/period-drill-down?period_kind=month&period=2024-02"
            f"&expected_data_revision={revision}&account_id={cash['id']}&cursor={cursor}",
            headers=auth,
        )
        assert tampered.status_code == 422, tampered.text
        assert tampered.json()["error"]["code"] == "invalid_period_report_cursor"

        _transaction(
            client,
            auth,
            {
                "kind": "expense",
                "amount_minor": 1,
                "occurred_at": "2024-02-20T12:00:00+08:00",
                "title": "revision changes",
                "account_id": cash["id"],
                "category_id": category["id"],
            },
        )
        stale = client.get(
            "/api/v1/reports/period-drill-down?period_kind=month&period=2024-02"
            f"&expected_data_revision={revision}",
            headers=auth,
        )
        assert stale.status_code == 409, stale.text
        assert stale.json()["error"]["code"] == "period_report_changed"
        assert (
            stale.json()["error"]["details"]["reload_path"]
            == "/api/v1/reports/period-drill-down?period_kind=month&period=2024-02"
        )
        for path, _, _, _ in exports:
            stale_export = client.get(f"{path}?expected_data_revision={revision}", headers=auth)
            assert stale_export.status_code == 409, stale_export.text
            error = stale_export.json()["error"]
            assert error["code"] == "period_report_changed"
            assert error["details"]["expected_data_revision"] == revision
            assert error["details"]["current_data_revision"] > revision
            assert error["details"]["safe_to_reload"] is True
            assert error["details"]["reload_path"] == path.removesuffix("/export.csv").removesuffix(
                "/export.pdf"
            )


def test_p34_bound_export_rejects_a_write_during_its_read_boundary(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A bound artifact cannot retry onto a newer revision after its owner changed."""
    app, auth = _app()
    with TestClient(app) as client:
        baseline = client.get("/api/v1/reports/monthly/2024-02", headers=auth)
        assert baseline.status_code == 200, baseline.text
        revision = baseline.json()["meta"]["data_revision"]
        original_data_revision = ReportingService._data_revision
        calls = 0

        async def revision_with_interleaved_formal_write(self: ReportingService) -> int:
            nonlocal calls
            calls += 1
            if calls == 2:
                writer_app, writer_auth = _app()
                with TestClient(writer_app) as writer:
                    created = writer.post(
                        "/api/v1/accounts",
                        headers=writer_auth,
                        json={
                            "name": "P34 export revision race",
                            "kind": "debit",
                            "opening_balance_minor": 0,
                        },
                    )
                assert created.status_code == 201, created.text
            return await original_data_revision(self)

        monkeypatch.setattr(
            ReportingService, "_data_revision", revision_with_interleaved_formal_write
        )
        response = client.get(
            f"/api/v1/reports/monthly/2024-02/export.csv?expected_data_revision={revision}",
            headers=auth,
        )

    assert calls == 2
    assert response.status_code == 409, response.text
    error = response.json()["error"]
    assert error["code"] == "period_report_changed"
    assert error["details"] == {
        "reason": "data_revision_changed",
        "expected_data_revision": revision,
        "current_data_revision": revision + 1,
        "safe_to_reload": True,
        "reload_path": "/api/v1/reports/monthly/2024-02",
    }


def test_p34_reimbursement_period_end_is_rebuilt_from_formal_revisions(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Later receipts cannot rewrite the closed month-end claim balance."""
    app, auth = _app()
    with TestClient(app) as client:
        cash = _account(client, auth, name="P34 历史报销卡")
        category = _category(client, auth)
        expense = _transaction(
            client,
            auth,
            {
                "kind": "expense",
                "amount_minor": 1_200,
                "occurred_at": "2024-02-28T12:00:00+08:00",
                "title": "P34 历史垫付",
                "account_id": cash["id"],
                "category_id": category["id"],
            },
        )
        created = client.post(
            "/api/v1/reimbursement-claims",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "title": "P34 历史报销",
                "parties": [
                    {
                        "name": "公司",
                        "allocations": [{"transaction_id": expense["id"], "amount_minor": 1_200}],
                    }
                ],
            },
        )
        assert created.status_code == 201, created.text
        claim = created.json()
        asyncio.run(
            _record_reimbursement_revision_at(
                claim_id=claim["id"],
                claim_version=claim["version"],
                claim_at=datetime(2024, 2, 28, 16, tzinfo=UTC),
                transaction_id=expense["id"],
                transaction_version=expense["version"],
                transaction_at=datetime(2024, 2, 28, 5, tzinfo=UTC),
            )
        )

        february = client.get("/api/v1/reports/monthly/2024-02", headers=auth)
        assert february.status_code == 200, february.text
        assert february.json()["summary"]["reimbursement_outstanding_at_period_end_minor"] == 1_200

        first_receipt = _post_receipt(
            client,
            auth,
            claim=claim,
            amount_minor=600,
            received_at="2024-03-10T12:00:00+08:00",
            destination_account_id=cash["id"],
        )
        after_first = client.get(f"/api/v1/reimbursement-claims/{claim['id']}", headers=auth)
        assert after_first.status_code == 200, after_first.text
        claim_after_first = after_first.json()
        asyncio.run(
            _record_reimbursement_revision_at(
                claim_id=claim["id"],
                claim_version=claim_after_first["version"],
                claim_at=datetime(2024, 3, 10, 5, tzinfo=UTC),
                receipt_id=first_receipt["id"],
                receipt_version=first_receipt["version"],
                receipt_at=datetime(2024, 3, 10, 5, tzinfo=UTC),
                transaction_id=first_receipt["transaction"]["id"],
                transaction_version=first_receipt["transaction"]["version"],
                transaction_at=datetime(2024, 3, 10, 5, tzinfo=UTC),
            )
        )
        march = client.get("/api/v1/reports/monthly/2024-03", headers=auth)
        assert march.status_code == 200, march.text
        assert march.json()["summary"]["reimbursement_outstanding_at_period_end_minor"] == 600

        second_receipt = _post_receipt(
            client,
            auth,
            claim=claim_after_first,
            amount_minor=600,
            received_at="2024-04-10T12:00:00+08:00",
            destination_account_id=cash["id"],
        )
        after_second = client.get(f"/api/v1/reimbursement-claims/{claim['id']}", headers=auth)
        assert after_second.status_code == 200, after_second.text
        claim_after_second = after_second.json()
        asyncio.run(
            _record_reimbursement_revision_at(
                claim_id=claim["id"],
                claim_version=claim_after_second["version"],
                claim_at=datetime(2024, 4, 10, 5, tzinfo=UTC),
                receipt_id=second_receipt["id"],
                receipt_version=second_receipt["version"],
                receipt_at=datetime(2024, 4, 10, 5, tzinfo=UTC),
                transaction_id=second_receipt["transaction"]["id"],
                transaction_version=second_receipt["transaction"]["version"],
                transaction_at=datetime(2024, 4, 10, 5, tzinfo=UTC),
            )
        )
        # These writes are recorded after every 2024 period end. They prove
        # historical reports never inspect mutable transaction rows.
        moved_source = client.put(
            f"/api/v1/transactions/{expense['id']}",
            headers=auth,
            json={
                "expected_version": expense["version"],
                "kind": "expense",
                "amount_minor": 1_200,
                "occurred_at": "2024-05-01T12:00:00+08:00",
                "title": "P34 历史垫付期后更正",
                "account_id": cash["id"],
                "category_id": category["id"],
            },
        )
        assert moved_source.status_code == 200, moved_source.text
        assert moved_source.json()["occurred_at"].startswith("2024-05-01")

        replacement_draft = {
            "expected_claim_version": claim_after_second["version"],
            "expected_receipt_version": first_receipt["version"],
            "party_id": first_receipt["party_id"],
            "amount_minor": 600,
            "received_at": "2024-05-02T12:00:00+08:00",
            "destination_account_id": cash["id"],
            "title": "P34 回款期后更正",
        }
        replacement_preview = client.post(
            f"/api/v1/reimbursement-receipts/{first_receipt['id']}/preview",
            headers=auth,
            json=replacement_draft,
        )
        assert replacement_preview.status_code == 200, replacement_preview.text
        replaced = client.put(
            f"/api/v1/reimbursement-receipts/{first_receipt['id']}",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                **replacement_draft,
                "preview_token": replacement_preview.json()["preview_token"],
            },
        )
        assert replaced.status_code == 200, replaced.text
        assert replaced.json()["received_at"].startswith("2024-05-02")

        current_claim = client.get(f"/api/v1/reimbursement-claims/{claim['id']}", headers=auth)
        assert current_claim.status_code == 200, current_claim.text
        voided = client.post(
            f"/api/v1/reimbursement-receipts/{first_receipt['id']}/void",
            headers=auth,
            json={
                "expected_claim_version": current_claim.json()["version"],
                "expected_receipt_version": replaced.json()["version"],
            },
        )
        assert voided.status_code == 200, voided.text
        claim_after_void = client.get(f"/api/v1/reimbursement-claims/{claim['id']}", headers=auth)
        assert claim_after_void.status_code == 200, claim_after_void.text
        restored = client.post(
            f"/api/v1/reimbursement-receipts/{first_receipt['id']}/restore",
            headers=auth,
            json={
                "expected_claim_version": claim_after_void.json()["version"],
                "expected_receipt_version": voided.json()["version"],
            },
        )
        assert restored.status_code == 200, restored.text

        february_after_edits = client.get("/api/v1/reports/monthly/2024-02", headers=auth)
        march_after_april_receipt = client.get("/api/v1/reports/monthly/2024-03", headers=auth)
        april = client.get("/api/v1/reports/monthly/2024-04", headers=auth)
        assert february_after_edits.status_code == march_after_april_receipt.status_code == 200
        assert april.status_code == 200, april.text
        assert (
            february_after_edits.json()["summary"]["reimbursement_outstanding_at_period_end_minor"]
            == 1_200
        )
        assert (
            march_after_april_receipt.json()["summary"][
                "reimbursement_outstanding_at_period_end_minor"
            ]
            == 600
        )
        assert april.json()["summary"]["reimbursement_outstanding_at_period_end_minor"] == 0

        password = uuid4().hex + uuid4().hex
        exported = client.post(
            "/api/v1/archives/export",
            headers=auth,
            json={"password": password, "include_ai_raw": False},
        )
        assert exported.status_code == 200, exported.text
        manifest, payload = ArchiveService.open(exported.content, password=password)
        expected_march_outstanding = march_after_april_receipt.json()["summary"][
            "reimbursement_outstanding_at_period_end_minor"
        ]

    target_name = f"fiscal_p34_archive_restore_{uuid4().hex}"
    target_url = _fresh_database_url(target_name)
    asyncio.run(_create_database(target_name))
    try:
        monkeypatch.setenv("FISCAL_DATABASE_URL", target_url)
        get_settings.cache_clear()
        command.upgrade(_alembic_config(), "head")

        async def restore_and_report() -> int:
            engine = create_engine(target_url)
            try:
                async with engine.begin() as connection:
                    await ArchiveService.restore_empty_target(
                        connection, manifest=manifest, payload=payload
                    )
                async with create_session_factory(engine)() as session:
                    report = await ReportingService(session).monthly_report(period="2024-03")
                    return report.summary.reimbursement_outstanding_at_period_end_minor
            finally:
                await engine.dispose()

        assert asyncio.run(restore_and_report()) == expected_march_outstanding
    finally:
        asyncio.run(_drop_database(target_name))
        monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
        get_settings.cache_clear()


def test_p34_reimbursement_cancellation_respects_the_year_boundary() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        cash = _account(client, auth, name="P34 跨年报销卡")
        category = _category(client, auth)
        expense = _transaction(
            client,
            auth,
            {
                "kind": "expense",
                "amount_minor": 700,
                "occurred_at": "2023-12-20T12:00:00+08:00",
                "title": "P34 跨年垫付",
                "account_id": cash["id"],
                "category_id": category["id"],
            },
        )
        created = client.post(
            "/api/v1/reimbursement-claims",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "title": "P34 跨年报销",
                "parties": [
                    {
                        "name": "公司",
                        "allocations": [{"transaction_id": expense["id"], "amount_minor": 700}],
                    }
                ],
            },
        )
        assert created.status_code == 201, created.text
        claim = created.json()
        asyncio.run(
            _record_reimbursement_revision_at(
                claim_id=claim["id"],
                claim_version=claim["version"],
                claim_at=datetime(2023, 12, 20, 5, tzinfo=UTC),
                transaction_id=expense["id"],
                transaction_version=expense["version"],
                transaction_at=datetime(2023, 12, 20, 5, tzinfo=UTC),
            )
        )
        submitted = client.post(
            f"/api/v1/reimbursement-claims/{claim['id']}/submit",
            headers=auth,
            json={"expected_version": claim["version"]},
        )
        assert submitted.status_code == 200, submitted.text
        claim = submitted.json()
        asyncio.run(
            _record_reimbursement_revision_at(
                claim_id=claim["id"],
                claim_version=claim["version"],
                claim_at=datetime(2023, 12, 21, 5, tzinfo=UTC),
            )
        )
        december = client.get("/api/v1/reports/monthly/2023-12", headers=auth)
        year_2023 = client.get("/api/v1/reports/yearly/2023", headers=auth)
        assert december.status_code == year_2023.status_code == 200
        assert december.json()["summary"]["reimbursement_outstanding_at_period_end_minor"] == 700
        assert year_2023.json()["summary"]["reimbursement_outstanding_at_period_end_minor"] == 700

        preview = client.post(
            f"/api/v1/reimbursement-claims/{claim['id']}/cancel-preview",
            headers=auth,
            json={"expected_version": claim["version"]},
        )
        assert preview.status_code == 200, preview.text
        cancelled = client.post(
            f"/api/v1/reimbursement-claims/{claim['id']}/cancel-outstanding",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "expected_version": claim["version"],
                "preview_token": preview.json()["preview_token"],
            },
        )
        assert cancelled.status_code == 200, cancelled.text
        cancelled_claim = cancelled.json()
        asyncio.run(
            _record_reimbursement_revision_at(
                claim_id=claim["id"],
                claim_version=cancelled_claim["version"],
                claim_at=datetime(2024, 1, 2, 5, tzinfo=UTC),
            )
        )
        assert (
            client.get("/api/v1/reports/monthly/2023-12", headers=auth).json()["summary"][
                "reimbursement_outstanding_at_period_end_minor"
            ]
            == 700
        )
        january = client.get("/api/v1/reports/monthly/2024-01", headers=auth)
        assert january.status_code == 200, january.text
        assert january.json()["summary"]["reimbursement_outstanding_at_period_end_minor"] == 0


def test_p36_report_v2_adds_auditable_dimensions_without_changing_v1() -> None:
    app, auth = _app()
    suffix = uuid4().hex[:8]
    with TestClient(app) as client:
        account = _account(client, auth, name=f"P36 报表账户 {suffix}")
        category = client.post(
            "/api/v1/categories",
            headers=auth,
            json={
                "name": f"P36 报表分类 {suffix}",
                "direction": "expense",
                "icon": "chart.bar",
                "color_hex": "#654321",
            },
        )
        assert category.status_code == 201, category.text
        category_body = category.json()
        transaction = _transaction(
            client,
            auth,
            {
                "kind": "expense",
                "amount_minor": 1_234,
                "occurred_at": "2026-08-19T12:00:00+08:00",
                "title": f"P36 审计消费 {suffix}",
                "account_id": account["id"],
                "category_id": category_body["id"],
            },
        )

        legacy = client.get("/api/v1/reports/monthly/2026-08", headers=auth)
        report = client.get("/api/v1/reports/v2/monthly/2026-08", headers=auth)
        assert legacy.status_code == report.status_code == 200
        legacy_body = legacy.json()
        body = report.json()
        assert legacy_body["meta"]["report_schema_version"] == "1"
        assert legacy_body["completeness"]["open_reconciliation_difference_count"] == 0
        assert "daily" not in legacy_body
        assert body["meta"]["report_schema_version"] == "2"
        assert "open_reconciliation_difference_count" not in body["completeness"]
        revision = body["meta"]["data_revision"]
        assert body["drill_down_path"] == (
            "/api/v1/reports/v2/period-drill-down"
            f"?period_kind=month&period=2026-08&expected_data_revision={revision}"
        )

        category_row = next(
            row for row in body["categories"] if row["category_id"] == category_body["id"]
        )
        assert {
            key: category_row[key]
            for key in (
                "gross_consumption_minor",
                "merchant_refund_minor",
                "net_consumption_minor",
                "expected_reimbursement_minor",
                "received_reimbursement_minor",
                "personal_expected_minor",
                "personal_realized_minor",
            )
        } == {
            "gross_consumption_minor": 1_234,
            "merchant_refund_minor": 0,
            "net_consumption_minor": 1_234,
            "expected_reimbursement_minor": 0,
            "received_reimbursement_minor": 0,
            "personal_expected_minor": 1_234,
            "personal_realized_minor": 1_234,
        }
        daily_row = next(row for row in body["daily"] if row["date"] == "2026-08-19")
        assert daily_row["gross_consumption_minor"] == 1_234
        assert daily_row["personal_realized_minor"] == 1_234
        assert isinstance(body["known_future_events"], list)
        assert isinstance(body["debt_cycles"], list)
        assert isinstance(body["installments"], list)

        drill = client.get(
            "/api/v1/reports/v2/period-drill-down"
            f"?period_kind=month&period=2026-08&expected_data_revision={revision}"
            f"&category_id={category_body['id']}",
            headers=auth,
        )
        assert drill.status_code == 200, drill.text
        item = next(
            row for row in drill.json()["items"] if row["transaction_id"] == transaction["id"]
        )
        assert item["title"] == transaction["title"]
        assert item["account_id"] == account["id"]
        assert item["account_name"] == account["name"]
        assert item["status"] == "active"
        assert item["account_archived"] is False
        assert item["category_archived"] is False

        exported = client.get(
            f"/api/v1/reports/v2/monthly/2026-08/export.csv?expected_data_revision={revision}",
            headers=auth,
        )
        assert exported.status_code == 200, exported.text
        assert exported.headers["x-fiscal-data-revision"] == str(revision)
        assert ",个人实际承担," in exported.text
        assert "personal_realized_minor" not in exported.text

        _transaction(
            client,
            auth,
            {
                "kind": "expense",
                "amount_minor": 1,
                "occurred_at": "2026-08-20T12:00:00+08:00",
                "title": f"P36 使报表失效 {suffix}",
                "account_id": account["id"],
                "category_id": category_body["id"],
            },
        )
        stale_drill = client.get(
            "/api/v1/reports/v2/period-drill-down"
            f"?period_kind=month&period=2026-08&expected_data_revision={revision}",
            headers=auth,
        )
        stale_export = client.get(
            f"/api/v1/reports/v2/monthly/2026-08/export.csv?expected_data_revision={revision}",
            headers=auth,
        )
        assert stale_drill.status_code == stale_export.status_code == 409
        assert stale_drill.json()["error"]["code"] == "period_report_changed"
        assert stale_export.json()["error"]["code"] == "period_report_changed"
