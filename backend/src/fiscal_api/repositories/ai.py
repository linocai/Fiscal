from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.db.models import (
    Account,
    AIExecutionPolicy,
    AILearningRule,
    AIProposal,
    AIQualityEvent,
    AISettings,
    Category,
)


class AIRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def settings(self, *, for_update: bool = False) -> AISettings:
        statement = select(AISettings).where(AISettings.id == 1)
        if for_update:
            statement = statement.with_for_update()
        value = await self.session.scalar(statement)
        if value is None:
            value = AISettings(id=1)
            self.session.add(value)
            await self.session.flush()
        return value

    async def by_idempotency_key(self, key: UUID) -> AIProposal | None:
        return await self.session.scalar(
            select(AIProposal).where(AIProposal.create_idempotency_key == key)
        )

    async def proposal(self, proposal_id: UUID, *, for_update: bool = False) -> AIProposal | None:
        statement = select(AIProposal).where(AIProposal.id == proposal_id)
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def page(
        self,
        *,
        status: str | None,
        cursor_time: datetime | None,
        cursor_id: UUID | None,
        limit: int,
    ) -> list[AIProposal]:
        statement = select(AIProposal)
        if status is not None:
            statement = statement.where(AIProposal.status == status)
        if cursor_time is not None and cursor_id is not None:
            statement = statement.where(
                or_(
                    AIProposal.created_at < cursor_time,
                    (AIProposal.created_at == cursor_time) & (AIProposal.id < cursor_id),
                )
            )
        statement = statement.order_by(AIProposal.created_at.desc(), AIProposal.id.desc()).limit(
            limit + 1
        )
        return list((await self.session.scalars(statement)).all())

    async def pending_count(self) -> int:
        value = await self.session.scalar(
            select(func.count()).select_from(AIProposal).where(AIProposal.status == "pending")
        )
        return int(value or 0)

    async def quality_events(self, proposal_id: UUID | None = None) -> list[AIQualityEvent]:
        statement = select(AIQualityEvent).order_by(AIQualityEvent.occurred_at, AIQualityEvent.id)
        if proposal_id is not None:
            statement = statement.where(AIQualityEvent.proposal_id == proposal_id)
        return list((await self.session.scalars(statement)).all())

    async def all_proposals(self) -> list[AIProposal]:
        return list((await self.session.scalars(select(AIProposal))).all())

    async def policies(self) -> list[AIExecutionPolicy]:
        return list(
            (
                await self.session.scalars(
                    select(AIExecutionPolicy).order_by(
                        AIExecutionPolicy.effective_at.desc(), AIExecutionPolicy.version.desc()
                    )
                )
            ).all()
        )

    async def latest_policy(self) -> AIExecutionPolicy | None:
        return await self.session.scalar(
            select(AIExecutionPolicy)
            .order_by(AIExecutionPolicy.effective_at.desc(), AIExecutionPolicy.version.desc())
            .limit(1)
        )

    async def rules(self, *, enabled_only: bool = False) -> list[AILearningRule]:
        statement = select(AILearningRule).order_by(AILearningRule.created_at, AILearningRule.id)
        if enabled_only:
            statement = statement.where(AILearningRule.enabled.is_(True))
        return list((await self.session.scalars(statement)).all())

    async def rule(self, rule_id: UUID, *, for_update: bool = False) -> AILearningRule | None:
        statement = select(AILearningRule).where(AILearningRule.id == rule_id)
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def matching_rule(
        self, *, rule_kind: str, normalized_key: str, source: str | None
    ) -> AILearningRule | None:
        return await self.session.scalar(
            select(AILearningRule).where(
                AILearningRule.rule_kind == rule_kind,
                AILearningRule.normalized_key == normalized_key,
                AILearningRule.source.is_(source)
                if source is None
                else AILearningRule.source == source,
                AILearningRule.enabled.is_(True),
            )
        )

    async def evidence_count(
        self, *, title: str, category_id: UUID | None = None, account_id: UUID | None = None
    ) -> int:
        statement = (
            select(func.count())
            .select_from(AIProposal)
            .where(AIProposal.final_confirmed_snapshot.is_not(None), AIProposal.title == title)
        )
        if category_id is not None:
            statement = statement.where(AIProposal.category_id == category_id)
        if account_id is not None:
            statement = statement.where(AIProposal.account_id == account_id)
        return int((await self.session.scalar(statement)) or 0)

    async def active_accounts(self) -> list[Account]:
        return list(
            (
                await self.session.scalars(
                    select(Account)
                    .where(Account.archived_at.is_(None))
                    .order_by(Account.sort_order, Account.created_at, Account.id)
                )
            ).all()
        )

    async def active_categories(self) -> list[Category]:
        return list(
            (
                await self.session.scalars(
                    select(Category)
                    .where(Category.archived_at.is_(None))
                    .order_by(Category.sort_order, Category.created_at, Category.id)
                )
            ).all()
        )

    def add(self, proposal: AIProposal) -> None:
        self.session.add(proposal)

    def add_quality_event(self, event: AIQualityEvent) -> None:
        self.session.add(event)

    def add_policy(self, policy: AIExecutionPolicy) -> None:
        self.session.add(policy)

    def add_rule(self, rule: AILearningRule) -> None:
        self.session.add(rule)
