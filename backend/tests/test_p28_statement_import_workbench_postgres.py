from __future__ import annotations

from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from test_p27_statement_import_review_postgres import _client, _seed, _snapshot

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
