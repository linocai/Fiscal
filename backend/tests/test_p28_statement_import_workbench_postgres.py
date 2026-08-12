from __future__ import annotations

import asyncio
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from fiscal_api.db.models.ledger import LedgerTransaction, Posting
from fiscal_api.db.models.statement_import import StatementImportRow
from fiscal_api.db.models.statement_import_confirmation import (
    StatementImportConfirmationOperation,
    StatementImportTransactionProvenance,
)
from fiscal_api.db.session import create_engine, create_session_factory
from test_p27_statement_import_review_postgres import (
    TEST_DATABASE_URL,
    _client,
    _row_ids,
    _seed,
    _snapshot,
)

pytestmark = pytest.mark.skipif(
    __import__("os").environ.get("FISCAL_TEST_DATABASE_URL") is None,
    reason="requires PostgreSQL",
)


def _evidence_only(client: TestClient) -> tuple[dict[str, object], dict[str, str]]:
    auth = {"Authorization": "Bearer p28-token"}
    created = client.post(
        "/api/v1/statement-imports",
        headers=auth,
        json={
            "document_sha256": uuid4().hex * 2,
            "byte_size": 100,
            "page_count": 2,
            "mime_type": "application/pdf",
            "display_name": "statement.pdf",
        },
    ).json()
    attempt = client.post(
        f"/api/v1/statement-imports/{created['id']}/attempts",
        headers=auth,
        json={"expected_version": created["version"]},
    )
    submitted = client.post(
        f"/api/v1/statement-imports/{created['id']}/evidence",
        headers=auth,
        json={
            "attempt_id": attempt.json()["id"],
            "expected_version": int(attempt.headers["X-Fiscal-Statement-Import-Version"]),
            "pages": [
                {
                    "page_number": 1,
                    "source_kind": "text",
                    "evidence_text_masked": "[REDACTED] 18.50",
                    "bounding_boxes": [],
                },
                {
                    "page_number": 2,
                    "source_kind": "unsupported",
                    "evidence_text_masked": None,
                    "bounding_boxes": [],
                },
            ],
            "rows": [
                {
                    "row_number": 1,
                    "page_number": 1,
                    "evidence_text_masked": "[REDACTED] 18.50",
                    "bounding_box": {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.1},
                }
            ],
        },
    )
    assert submitted.status_code == 200
    return submitted.json(), auth


def test_workbench_is_masked_read_only_and_evidence_only_for_p28a_batch() -> None:
    with _client() as client:
        batch, auth = _evidence_only(client)
        response = client.get(
            f"/api/v1/statement-imports/{batch['id']}/review-workbench", headers=auth
        )
        assert response.status_code == 200
        body = response.json()
        assert body["review_available"] is False
        assert body["validation_run_id"] is None
        assert body["rows"][0]["evidence_text_masked"] == "[REDACTED] 18.50"
        encoded = response.text.lower()
        for forbidden in ("pdf", "image", "path", "bookmark", "raw_filename", "provider"):
            assert forbidden not in encoded
        missing = client.get(
            f"/api/v1/statement-imports/{batch['id']}/review-workbench/pages/2", headers=auth
        )
        assert missing.status_code == 200
        assert missing.json()["source_available"] is False


def test_workbench_cursor_filter_and_review_projection_are_read_only() -> None:
    with _client() as client:
        provider, auth = _seed(client, row_count=2)
        batch_id = provider["id"]
        snapshot = __import__("asyncio").run(_snapshot(__import__("uuid").UUID(batch_id)))
        run = client.post(
            f"/api/v1/statement-imports/{batch_id}/validation-runs",
            headers=auth,
            json={
                "expected_batch_version": provider["version"],
                "provider_snapshot_id": str(snapshot),
            },
        )
        assert run.status_code == 201, run.text
        response = client.get(
            f"/api/v1/statement-imports/{batch_id}/review-workbench?limit=1", headers=auth
        )
        assert response.status_code == 200
        body = response.json()
        assert body["review_available"] is True
        assert len(body["checks"]) == 5
        assert len(body["rows"]) == 1
        assert body["next_cursor"] == 1
        filtered = client.get(
            f"/api/v1/statement-imports/{batch_id}/review-workbench",
            headers=auth,
            params={"filters": '{"evidence_state":"available"}'},
        )
        assert filtered.status_code == 200
        assert all(row["evidence_text_masked"] for row in filtered.json()["rows"])
        assert (
            client.get(f"/api/v1/statement-imports/{batch_id}", headers=auth).json()["version"]
            == body["batch_version"]
        )


def test_confirmation_preview_is_read_only_canonical_and_receipt_is_persisted_only() -> None:
    with _client() as client:
        batch, auth = _seed(client, row_count=2)
        batch_id = batch["id"]
        snapshot = asyncio.run(_snapshot(__import__("uuid").UUID(batch_id)))
        review = client.post(
            f"/api/v1/statement-imports/{batch_id}/validation-runs",
            headers=auth,
            json={
                "expected_batch_version": batch["version"],
                "provider_snapshot_id": str(snapshot),
            },
        )
        assert review.status_code == 201, review.text
        selected_id = review.json()["candidates"][0]["statement_import_row_id"]
        other_id = str(asyncio.run(_row_ids(__import__("uuid").UUID(batch_id)))[1])
        resolution = client.put(
            f"/api/v1/statement-imports/{batch_id}/rows/{selected_id}/draft-resolution",
            headers=auth,
            json={
                "expected_batch_version": review.json()["batch_version"],
                "expected_row_version": 1,
                "expected_resolution_version": 0,
                "resolution": "ignore_intentional",
                "ignored_reason": "Not a personal transaction",
            },
        )
        assert resolution.status_code == 200, resolution.text

        async def mutation_counts() -> tuple[int, int, int, int, int]:
            engine = create_engine(TEST_DATABASE_URL)
            try:
                async with create_session_factory(engine)() as session:
                    return (
                        int(
                            await session.scalar(
                                select(func.count()).select_from(LedgerTransaction)
                            )
                            or 0
                        ),
                        int(await session.scalar(select(func.count()).select_from(Posting)) or 0),
                        int(
                            await session.scalar(
                                select(func.count()).select_from(StatementImportTransactionProvenance)
                            )
                            or 0
                        ),
                        int(
                            await session.scalar(
                                select(func.count()).select_from(StatementImportConfirmationOperation)
                            )
                            or 0
                        ),
                        int(
                            await session.scalar(
                                select(func.count())
                                .select_from(StatementImportRow)
                                .where(StatementImportRow.confirmed_at.is_not(None))
                            )
                            or 0
                        ),
                    )
            finally:
                await engine.dispose()

        before = asyncio.run(mutation_counts())
        preview = client.post(
            f"/api/v1/statement-imports/{batch_id}/confirmation-preview",
            headers=auth,
            json={"row_ids": [selected_id]},
        )
        assert preview.status_code == 200, preview.text
        body = preview.json()
        assert body["counts"] == {
            "selected": 1,
            "create_new": 0,
            "match_existing": 0,
            "ignore_non_transaction": 0,
            "ignore_intentional": 1,
            "unresolved": 0,
            "batch_unresolved": 1,
        }
        assert body["amounts"] == {
            "known_create_minor": 0,
            "known_match_minor": 0,
            "known_total_minor": 0,
            "unknown_selected_count": 1,
        }
        assert body["request"] == {
            "expected_batch_version": resolution.json()["batch_version"],
            "rows": [
                {
                    "row_id": selected_id,
                    "expected_row_version": 1,
                    "expected_draft_version": 1,
                    "expected_final_create_draft_version": None,
                }
            ],
        }
        assert asyncio.run(mutation_counts()) == before
        duplicate = client.post(
            f"/api/v1/statement-imports/{batch_id}/confirmation-preview",
            headers=auth,
            json={"row_ids": [selected_id, selected_id]},
        )
        assert duplicate.status_code == 409
        unresolved = client.post(
            f"/api/v1/statement-imports/{batch_id}/confirmation-preview",
            headers=auth,
            json={"row_ids": [other_id]},
        )
        assert unresolved.status_code == 409

        key = str(uuid4())
        confirmed = client.post(
            f"/api/v1/statement-imports/{batch_id}/confirm",
            headers={**auth, "Idempotency-Key": key},
            json=body["request"],
        )
        assert confirmed.status_code == 200, confirmed.text
        receipt = client.get(
            f"/api/v1/statement-imports/{batch_id}/confirmation-receipt",
            headers={**auth, "Idempotency-Key": key},
        )
        assert receipt.status_code == 200, receipt.text
        assert receipt.json() == {**confirmed.json(), "replay": True}
        missing = client.get(
            f"/api/v1/statement-imports/{batch_id}/confirmation-receipt",
            headers={**auth, "Idempotency-Key": str(uuid4())},
        )
        assert missing.status_code == 404
        workbench = client.get(
            f"/api/v1/statement-imports/{batch_id}/review-workbench", headers=auth
        )
        assert workbench.status_code == 200
        assert workbench.json()["rows"][0]["is_confirmed"] is True
