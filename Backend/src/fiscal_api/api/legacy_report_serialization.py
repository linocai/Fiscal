"""One-release response shims for clients installed before the v1.7 contract.

These keys are deliberately added only after the current public models have
been serialized.  Keeping them out of route response models prevents retired
concepts from remaining in the generated OpenAPI contract while allowing an
already-installed client to finish its transition safely.
"""

from typing import Any, cast

from fastapi.responses import JSONResponse

from fiscal_api.api.p7_schemas import FactsDrillDownPage, ReportFacts
from fiscal_api.api.p34_schemas import PeriodReport


def facts_response(value: ReportFacts) -> JSONResponse:
    content = value.model_dump(mode="json")
    completeness = cast(dict[str, Any], content["completeness"])
    completeness["open_reconciliation_difference_count"] = 0
    completeness["last_reconciled_at"] = None
    return JSONResponse(content=content)


def facts_drill_down_response(value: FactsDrillDownPage) -> JSONResponse:
    content = value.model_dump(mode="json")
    for item in cast(list[dict[str, Any]], content["items"]):
        if item.get("item_type") == "cash_account":
            item["last_reconciled_at"] = None
    return JSONResponse(content=content)


def period_report_response(value: PeriodReport) -> JSONResponse:
    content = value.model_dump(mode="json")
    completeness = cast(dict[str, Any], content["completeness"])
    completeness["open_reconciliation_difference_count"] = 0
    return JSONResponse(content=content)
