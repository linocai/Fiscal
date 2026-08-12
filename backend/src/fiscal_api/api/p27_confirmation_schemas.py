from __future__ import annotations

from typing import Annotated
from uuid import UUID

from pydantic import Field

from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p24_schemas import P24Model


class StatementImportFinalCreateDraftPut(P24Model):
    expected_version: Annotated[int, Field(ge=0)]
    transaction: TransactionDraft


class StatementImportFinalCreateDraftResponse(P24Model):
    id: UUID
    statement_import_row_id: UUID
    draft_resolution_id: UUID
    transaction: TransactionDraft
    version: int


class StatementImportConfirmationRow(P24Model):
    row_id: UUID
    expected_row_version: Annotated[int, Field(ge=1)]
    expected_draft_version: Annotated[int, Field(ge=1)]
    expected_final_create_draft_version: Annotated[int, Field(ge=1)] | None = None


class StatementImportConfirmRequest(P24Model):
    expected_batch_version: Annotated[int, Field(ge=1)]
    rows: list[StatementImportConfirmationRow] = Field(min_length=1, max_length=1000)


class StatementImportConfirmReceipt(P24Model):
    operation_id: UUID
    batch_id: UUID
    batch_version: int
    status: str
    confirmed_row_ids: list[UUID]
    replay: bool
