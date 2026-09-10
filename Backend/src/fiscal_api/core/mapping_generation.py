"""Deterministic 0038 archive adaptation matching migration 0039."""

from collections.abc import MutableMapping, Sequence
from typing import cast


def backfill_mapping_generations(
    transactions: Sequence[MutableMapping[str, object]],
    mappings: Sequence[MutableMapping[str, object]],
    operations: Sequence[MutableMapping[str, object]],
) -> None:
    maxima: dict[str, int] = {}
    for mapping in mappings:
        key, version = str(mapping["transaction_id"]), int(str(mapping["version"]))
        maxima[key] = max(maxima.get(key, 0), version)
    for operation in operations:
        receipt = operation.get("receipt")
        if not isinstance(receipt, dict):
            continue
        mapping = cast(dict[str, object], receipt).get("mapping")
        if not isinstance(mapping, dict):
            continue
        typed_mapping = cast(dict[str, object], mapping)
        key, version = (
            str(typed_mapping.get("transaction_id")),
            typed_mapping.get("mapping_version"),
        )
        if isinstance(version, int) and not isinstance(version, bool) and version >= 0:
            maxima[key] = max(maxima.get(key, 0), version)
    generations = {key: value + 1 for key, value in maxima.items()}
    for transaction in transactions:
        transaction["merchant_mapping_generation"] = generations.get(str(transaction["id"]), 0)
    for mapping in mappings:
        mapping["version"] = generations[str(mapping["transaction_id"])]
