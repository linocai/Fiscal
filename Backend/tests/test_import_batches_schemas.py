from datetime import UTC, datetime
from uuid import uuid4

import pytest
from pydantic import ValidationError

from fiscal_api.api.import_batch_schemas import ImportBatchCreate


def _candidate(client_id: str = "row-1") -> dict[str, object]:
    return {
        "client_id": client_id,
        "kind": "expense",
        "amount_minor": 1280,
        "occurred_at": datetime(2026, 10, 1, 12, 0, tzinfo=UTC).isoformat(),
        "title": "Coffee",
        "account_id": str(uuid4()),
    }


def test_import_batch_normalizes_fingerprint_and_rejects_duplicate_client_ids() -> None:
    request = ImportBatchCreate(
        source="structured",
        original_content_sha256="A" * 64,
        candidates=[_candidate(), _candidate("row-2")],
        idempotency_key="batch-key-1",
    )
    assert request.original_content_sha256 == "a" * 64
    assert request.candidates[0].amount_minor == 1280

    with pytest.raises(ValidationError, match="unique"):
        ImportBatchCreate(
            source="structured",
            original_content_sha256="a" * 64,
            candidates=[_candidate(), _candidate()],
            idempotency_key="batch-key-2",
        )


def test_import_batch_requires_aware_candidate_datetime() -> None:
    candidate = _candidate()
    candidate["occurred_at"] = "2026-10-01T12:00:00"
    with pytest.raises(ValidationError, match="timezone"):
        ImportBatchCreate(
            source="structured",
            original_content_sha256="a" * 64,
            candidates=[candidate],
            idempotency_key="batch-key-3",
        )
