from datetime import date, datetime
from uuid import UUID

from sqlalchemy import Select, and_, exists, func, or_, select, text
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from fiscal_api.db.models import (
    CreditCycle,
    InstallmentLedgerLink,
    InstallmentOperation,
    InstallmentPeriod,
    InstallmentPlan,
    InstallmentPlanRevision,
    LedgerTransaction,
    Posting,
    TransactionSource,
)


class InstallmentRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def plan(self, plan_id: UUID, *, for_update: bool = False) -> InstallmentPlan | None:
        statement = (
            select(InstallmentPlan)
            .where(InstallmentPlan.id == plan_id)
            .options(selectinload(InstallmentPlan.periods))
        )
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def plan_for_purchase(self, transaction_id: UUID) -> InstallmentPlan | None:
        return await self.session.scalar(
            select(InstallmentPlan)
            .where(InstallmentPlan.purchase_transaction_id == transaction_id)
            .options(selectinload(InstallmentPlan.periods))
        )

    async def plan_for_idempotency(self, key: UUID) -> InstallmentPlan | None:
        return await self.session.scalar(
            select(InstallmentPlan)
            .where(InstallmentPlan.create_idempotency_key == key)
            .options(selectinload(InstallmentPlan.periods))
        )

    async def plans(
        self,
        *,
        account_id: UUID | None,
        status: str | None,
        limit: int,
        cursor_created_at: datetime | None,
        cursor_id: UUID | None,
    ) -> list[InstallmentPlan]:
        statement: Select[tuple[InstallmentPlan]] = select(InstallmentPlan).options(
            selectinload(InstallmentPlan.periods)
        )
        if account_id is not None:
            statement = statement.where(InstallmentPlan.credit_account_id == account_id)
        completed_sql = """
            EXISTS (SELECT 1 FROM installment_periods present
                    WHERE present.plan_id=installment_plans.id
                      AND present.cancelled_at IS NULL)
            AND NOT EXISTS (
                SELECT 1 FROM installment_periods ip
                JOIN credit_cycles c ON c.id=ip.effective_cycle_id
                WHERE ip.plan_id=installment_plans.id AND ip.cancelled_at IS NULL
                  AND (
                    COALESCE((SELECT SUM(ap.principal_minor+ap.fee_minor)
                              FROM installment_periods ap
                              WHERE ap.effective_cycle_id=ip.effective_cycle_id
                                AND ap.cancelled_at IS NULL),0)
                    + COALESCE((SELECT SUM(-po.amount_minor)
                                FROM transactions tx JOIN postings po
                                  ON po.transaction_id=tx.id
                                WHERE tx.credit_cycle_id=ip.effective_cycle_id
                                  AND tx.kind='credit_purchase'
                                  AND tx.voided_at IS NULL
                                  AND NOT EXISTS (SELECT 1 FROM installment_ledger_links ll
                                                  WHERE ll.transaction_id=tx.id)),0)
                    + CASE WHEN c.is_opening_cycle THEN
                        (SELECT opening_balance_minor FROM accounts WHERE id=c.account_id)
                      ELSE 0 END
                    - COALESCE((SELECT SUM(po.amount_minor)
                                FROM transactions tx JOIN postings po
                                  ON po.transaction_id=tx.id
                                WHERE tx.credit_cycle_id=ip.effective_cycle_id
                                  AND tx.kind='repayment' AND tx.voided_at IS NULL
                                  AND po.role='destination'),0)
                  ) <> 0
            )
            """
        completed = text(completed_sql)
        not_completed = text(f"NOT ({completed_sql})")
        if status == "cancelled":
            statement = statement.where(InstallmentPlan.lifecycle == "cancelled")
        elif status == "settled_early":
            statement = statement.where(InstallmentPlan.lifecycle == "settled_early")
        elif status == "completed":
            statement = statement.where(
                InstallmentPlan.lifecycle.in_(["active", "partially_cancelled"]), completed
            )
        elif status == "partially_cancelled":
            statement = statement.where(
                InstallmentPlan.lifecycle == "partially_cancelled", not_completed
            )
        elif status == "active":
            statement = statement.where(InstallmentPlan.lifecycle == "active", not_completed)
        if cursor_created_at is not None and cursor_id is not None:
            statement = statement.where(
                or_(
                    InstallmentPlan.created_at < cursor_created_at,
                    and_(
                        InstallmentPlan.created_at == cursor_created_at,
                        InstallmentPlan.id < cursor_id,
                    ),
                )
            )
        return list(
            (
                await self.session.scalars(
                    statement.order_by(
                        InstallmentPlan.created_at.desc(), InstallmentPlan.id.desc()
                    ).limit(limit + 1)
                )
            ).all()
        )

    async def linked(self, transaction_id: UUID) -> InstallmentLedgerLink | None:
        return await self.session.scalar(
            select(InstallmentLedgerLink).where(
                InstallmentLedgerLink.transaction_id == transaction_id
            )
        )

    async def plan_link(self, plan_id: UUID, role: str) -> InstallmentLedgerLink | None:
        return await self.session.scalar(
            select(InstallmentLedgerLink).where(
                InstallmentLedgerLink.plan_id == plan_id,
                InstallmentLedgerLink.role == role,
            )
        )

    async def transaction(self, transaction_id: UUID) -> LedgerTransaction | None:
        return await self.session.scalar(
            select(LedgerTransaction)
            .where(LedgerTransaction.id == transaction_id)
            .options(selectinload(LedgerTransaction.postings))
        )

    async def cycle_by_statement(
        self, account_id: UUID, statement_date: date
    ) -> CreditCycle | None:
        return await self.session.scalar(
            select(CreditCycle).where(
                CreditCycle.account_id == account_id,
                CreditCycle.statement_date == statement_date,
                CreditCycle.is_opening_cycle.is_(False),
            )
        )

    async def cycle_has_repayment(self, cycle_id: UUID) -> bool:
        return bool(
            await self.session.scalar(
                select(
                    exists().where(
                        LedgerTransaction.credit_cycle_id == cycle_id,
                        LedgerTransaction.kind == "repayment",
                        LedgerTransaction.voided_at.is_(None),
                    )
                )
            )
        )

    async def cycle_has_later_repayment(
        self,
        cycle_id: UUID,
        *,
        occurred_after: datetime,
        created_after: datetime,
        excluding_transaction_id: UUID,
    ) -> bool:
        return bool(
            await self.session.scalar(
                select(
                    exists().where(
                        LedgerTransaction.credit_cycle_id == cycle_id,
                        LedgerTransaction.kind == "repayment",
                        LedgerTransaction.source.in_(
                            [TransactionSource.MANUAL.value, TransactionSource.AI_TEXT.value]
                        ),
                        LedgerTransaction.voided_at.is_(None),
                        LedgerTransaction.id != excluding_transaction_id,
                        or_(
                            LedgerTransaction.occurred_at > occurred_after,
                            LedgerTransaction.created_at > created_after,
                        ),
                    )
                )
            )
        )

    async def active_period_totals(self, cycle_ids: list[UUID]) -> dict[UUID, tuple[int, int]]:
        if not cycle_ids:
            return {}
        rows = await self.session.execute(
            select(
                InstallmentPeriod.effective_cycle_id,
                func.sum(InstallmentPeriod.principal_minor),
                func.sum(InstallmentPeriod.fee_minor),
            )
            .where(
                InstallmentPeriod.effective_cycle_id.in_(cycle_ids),
                InstallmentPeriod.cancelled_at.is_(None),
            )
            .group_by(InstallmentPeriod.effective_cycle_id)
        )
        return {cycle_id: (int(principal), int(fee)) for cycle_id, principal, fee in rows}

    async def period_plans_for_cycle(self, cycle_id: UUID) -> list[InstallmentPlan]:
        return list(
            (
                await self.session.scalars(
                    select(InstallmentPlan)
                    .where(
                        exists().where(
                            InstallmentPeriod.plan_id == InstallmentPlan.id,
                            InstallmentPeriod.effective_cycle_id == cycle_id,
                        )
                    )
                    .options(selectinload(InstallmentPlan.periods))
                )
            ).unique()
        )

    async def linked_transaction_ids(self) -> set[UUID]:
        return set((await self.session.scalars(select(InstallmentLedgerLink.transaction_id))).all())

    def add_all(self, *objects: object) -> None:
        self.session.add_all(list(objects))

    def add_revision(self, revision: InstallmentPlanRevision) -> None:
        self.session.add(revision)

    async def snapshot(self, plan_id: UUID, version: int) -> dict[str, object] | None:
        return await self.session.scalar(
            select(InstallmentPlanRevision.snapshot).where(
                InstallmentPlanRevision.plan_id == plan_id,
                InstallmentPlanRevision.version == version,
            )
        )

    async def operation_for_key(self, key: UUID) -> InstallmentOperation | None:
        return await self.session.scalar(
            select(InstallmentOperation).where(InstallmentOperation.idempotency_key == key)
        )

    async def latest_settlement(self, plan_id: UUID) -> InstallmentOperation | None:
        return await self.session.scalar(
            select(InstallmentOperation)
            .where(
                InstallmentOperation.plan_id == plan_id,
                InstallmentOperation.kind == "settle_early",
                InstallmentOperation.completed_at.is_not(None),
                InstallmentOperation.reversed_at.is_(None),
            )
            .order_by(InstallmentOperation.created_at.desc())
            .limit(1)
        )

    async def link_for_operation(
        self, operation_id: UUID, role: str
    ) -> InstallmentLedgerLink | None:
        return await self.session.scalar(
            select(InstallmentLedgerLink).where(
                InstallmentLedgerLink.operation_id == operation_id,
                InstallmentLedgerLink.role == role,
            )
        )

    async def has_later_operation(self, plan_id: UUID, created_at: datetime) -> bool:
        return bool(
            await self.session.scalar(
                select(
                    exists().where(
                        InstallmentOperation.plan_id == plan_id,
                        InstallmentOperation.created_at > created_at,
                    )
                )
            )
        )

    async def account_impact(self, account_id: UUID) -> int:
        value = await self.session.scalar(
            select(func.coalesce(func.sum(Posting.amount_minor), 0))
            .join(LedgerTransaction, LedgerTransaction.id == Posting.transaction_id)
            .where(Posting.account_id == account_id, LedgerTransaction.voided_at.is_(None))
        )
        return int(value or 0)
