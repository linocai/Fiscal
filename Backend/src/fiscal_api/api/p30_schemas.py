from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fiscal_api.api.p24_schemas import P24Model
from fiscal_api.db.models import MigrationRunMode, MigrationRunStatus


class MigrationRunResponse(P24Model):
    id: UUID
    mode: MigrationRunMode
    status: MigrationRunStatus
    source_system: str
    code_revision: str
    started_at: datetime
    completed_at: datetime | None
    deep_link: str
