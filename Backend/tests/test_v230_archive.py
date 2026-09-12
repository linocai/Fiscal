from __future__ import annotations

from copy import deepcopy
from uuid import uuid4

import pytest

from fiscal_api.db.base import Base
from fiscal_api.services.archive import (
    CURRENT_DATABASE_REVISION,
    ArchiveError,
    ArchiveService,
    _archive_tables,
    _legacy_cash_flow_links,
)


@pytest.mark.parametrize("source", ["20260831_0038", "20260910_0039"])
def test_legacy_archive_source_validation_and_empty_domain_adaptation(source):
    new_tables = {"cash_flow_settlement_links", "credit_payoff_operations", "credit_payoff_links"}
    entities = {t.name: [] for t in _archive_tables(Base.metadata) if t.name not in new_tables}
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
    assert report["original_archive_unchanged"]
    assert (manifest, payload) == original
    malformed = deepcopy(payload)
    malformed["entities"]["credit_payoff_operations"] = []
    with pytest.raises(ArchiveError):
        ArchiveService.adapt_to_current(manifest, malformed)


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
