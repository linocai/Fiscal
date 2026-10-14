from __future__ import annotations

from copy import deepcopy
from uuid import uuid4

import pytest

from fiscal_api.db.base import Base
from fiscal_api.services.archive import (
    _AI_REDACTED_RAW_INPUT,
    _RETIRED_V240_TABLES,
    _V43_TABLES,
    CURRENT_DATABASE_REVISION,
    ArchiveError,
    ArchiveService,
    _archive_tables,
    _legacy_cash_flow_links,
    _redact_candidate_source_text,
)


@pytest.mark.parametrize(
    "source",
    [
        "20260831_0038",
        "20260910_0039",
        "20260912_0040",
        "20260922_0041",
        "20260926_0042",
    ],
)
def test_legacy_archive_source_validation_and_empty_domain_adaptation(source):
    new_tables = {"cash_flow_settlement_links", "credit_payoff_operations", "credit_payoff_links"}
    omitted = new_tables if source in {"20260831_0038", "20260910_0039"} else set()
    omitted = omitted | _V43_TABLES
    entities = {t.name: [] for t in _archive_tables(Base.metadata) if t.name not in omitted}
    if source != "20260926_0042":
        entities.update({name: [] for name in _RETIRED_V240_TABLES})
    payload = {"entities": entities, "data_revision": 1}
    manifest = {
        "database_revision": source,
        "data_revision": 1,
        "entity_counts": {k: 0 for k in entities},
    }
    original = deepcopy((manifest, payload))
    converted, content, report = ArchiveService.adapt_to_current(manifest, payload)
    assert converted["database_revision"] == CURRENT_DATABASE_REVISION
    assert new_tables <= content["entities"].keys()
    assert content["entities"]["import_batches"] == []
    assert "import_batches" in report["added_fields"]
    assert report["original_archive_unchanged"]
    assert (manifest, payload) == original
    malformed = deepcopy(payload)
    if omitted - _V43_TABLES:
        malformed["entities"]["credit_payoff_operations"] = []
    else:
        del malformed["entities"]["credit_payoff_operations"]
    with pytest.raises(ArchiveError):
        ArchiveService.adapt_to_current(manifest, malformed)


def test_pre_0043_archive_must_not_carry_import_batches():
    entities = {t.name: [] for t in _archive_tables(Base.metadata)}
    manifest = {
        "database_revision": "20260926_0042",
        "data_revision": 1,
        "entity_counts": {k: 0 for k in entities},
    }
    with pytest.raises(ArchiveError, match="entity set"):
        ArchiveService.adapt_to_current(manifest, {"entities": entities, "data_revision": 1})


def test_import_batch_source_text_follows_ai_raw_policy():
    candidates = [
        {"client_id": "a", "title": "午饭", "source_text": "10/14 午饭 32.5"},
        {"client_id": "b", "title": "地铁"},
    ]
    redacted = _redact_candidate_source_text(candidates)
    assert redacted == [
        {"client_id": "a", "title": "午饭", "source_text": _AI_REDACTED_RAW_INPUT},
        {"client_id": "b", "title": "地铁"},
    ]
    assert candidates[0]["source_text"] == "10/14 午饭 32.5"


def test_0041_nonempty_pdf_archive_is_rejected_without_mutating_original():
    entities = {t.name: [] for t in _archive_tables(Base.metadata) if t.name not in _V43_TABLES}
    entities.update({name: [] for name in _RETIRED_V240_TABLES})
    entities["statement_imports"] = [{"id": str(uuid4())}]
    payload = {"entities": entities, "data_revision": 1}
    manifest = {
        "database_revision": "20260922_0041",
        "data_revision": 1,
        "entity_counts": {name: len(rows) for name, rows in entities.items()},
    }
    original = deepcopy((manifest, payload))
    with pytest.raises(ArchiveError, match="nonempty PDF import history"):
        ArchiveService.adapt_to_current(manifest, payload)
    assert (manifest, payload) == original


def test_legacy_cashflow_backfill_retains_superseded_and_rejects_ambiguous():
    item, old_tx, new_tx = str(uuid4()), str(uuid4()), str(uuid4())
    entities = {
        "transactions": [{"id": old_tx}, {"id": new_tx}],
        "cash_flow_items": [
            {"id": item, "linked_transaction_id": new_tx, "created_at": "2026-09-01T00:00:00Z"}
        ],
        "cash_flow_item_revisions": [
            {"item_id": item, "snapshot": {"linked_transaction_id": old_tx}},
            {"item_id": item, "snapshot": {"linked_transaction_id": new_tx}},
        ],
    }
    links = _legacy_cash_flow_links(entities)
    assert {x["transaction_id"] for x in links} == {old_tx, new_tx}
    assert all(x["closes_remainder"] for x in links)
    entities["cash_flow_items"].append(
        {"id": str(uuid4()), "linked_transaction_id": old_tx, "created_at": "2026-09-01T00:00:00Z"}
    )
    with pytest.raises(ArchiveError, match="ambiguous"):
        _legacy_cash_flow_links(entities)
