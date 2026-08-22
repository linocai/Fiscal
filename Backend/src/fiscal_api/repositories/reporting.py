from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
from typing import cast
from uuid import UUID

from sqlalchemy import String, and_, case, exists, func, literal, or_, select
from sqlalchemy import cast as sql_cast
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased, selectinload
from sqlalchemy.sql.elements import ColumnElement

from fiscal_api.db.models import (
    Account,
    CashFlowItem,
    Category,
    CreditCycle,
    InstallmentLedgerLink,
    InstallmentPeriod,
    InstallmentPlan,
    LedgerTransaction,
    Posting,
    ReconciliationCheckpoint,
    ReimbursementAllocation,
    ReimbursementClaim,
    ReimbursementClaimRevision,
    ReimbursementParty,
    ReimbursementReceipt,
    ReimbursementReceiptAllocation,
    ReimbursementReceiptRevision,
    StatementImport,
    TransactionMerchantMapping,
    TransactionRevision,
)
from fiscal_api.services.common import checked_int64


@dataclass(frozen=True)
class RefundFact:
    source_transaction_id: UUID
    refund_transaction_id: UUID
    amount_minor: int


@dataclass(frozen=True)
class ReimbursementFact:
    allocation_id: UUID
    source_transaction_id: UUID
    claim_id: UUID
    party_id: UUID
    party_name: str
    expected_date: date | None
    submitted_at: datetime | None
    cancelled_at: datetime | None
    claim_voided_at: datetime | None
    allocated_minor: int
    received_minor: int


@dataclass(frozen=True)
class FutureReimbursementRow:
    claim_id: UUID
    party_id: UUID
    party_name: str
    expected_date: date
    outstanding_minor: int


def _future_after(
    *,
    date_column: ColumnElement[date],
    direction_column: ColumnElement[str],
    source_type: str,
    source_id_column: ColumnElement[str],
    cursor: tuple[date, str, str, UUID] | None,
) -> ColumnElement[bool]:
    """SQL predicate for the canonical future-event tuple ordering."""
    if cursor is None:
        return literal(True)
    cursor_date, cursor_direction, cursor_source_type, cursor_id = cursor
    same_day = or_(
        direction_column > cursor_direction,
        and_(
            direction_column == cursor_direction,
            or_(
                literal(source_type) > cursor_source_type,
                and_(
                    literal(source_type) == cursor_source_type,
                    source_id_column > str(cursor_id),
                ),
            ),
        ),
    )
    return or_(date_column > cursor_date, and_(date_column == cursor_date, same_day))


class ReportingRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def transactions(
        self,
        *,
        occurred_from: datetime | None = None,
        occurred_to_exclusive: datetime | None = None,
        kinds: set[str] | None = None,
        excluded_category_ids: set[UUID] | None = None,
    ) -> list[LedgerTransaction]:
        statement = (
            select(LedgerTransaction)
            .where(LedgerTransaction.voided_at.is_(None))
            .options(selectinload(LedgerTransaction.postings))
        )
        if occurred_from is not None:
            statement = statement.where(LedgerTransaction.occurred_at >= occurred_from)
        if occurred_to_exclusive is not None:
            statement = statement.where(LedgerTransaction.occurred_at < occurred_to_exclusive)
        if kinds is not None:
            statement = statement.where(LedgerTransaction.kind.in_(kinds))
        if excluded_category_ids:
            statement = statement.where(
                or_(
                    LedgerTransaction.category_id.is_(None),
                    LedgerTransaction.category_id.not_in(excluded_category_ids),
                )
            )
        statement = statement.order_by(
            LedgerTransaction.occurred_at.desc(), LedgerTransaction.id.desc()
        )
        return list((await self.session.scalars(statement)).all())

    async def transaction_page(
        self,
        *,
        occurred_from: datetime,
        occurred_to_exclusive: datetime,
        kinds: set[str],
        category_ids: set[UUID] | None,
        excluded_category_ids: set[UUID] | None,
        account_id: UUID | None,
        cursor_time: datetime | None,
        cursor_id: UUID | None,
        limit: int,
    ) -> list[LedgerTransaction]:
        statement = (
            select(LedgerTransaction)
            .where(
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.kind.in_(kinds),
                LedgerTransaction.occurred_at >= occurred_from,
                LedgerTransaction.occurred_at < occurred_to_exclusive,
            )
            .options(selectinload(LedgerTransaction.postings))
        )
        if category_ids is not None:
            statement = statement.where(LedgerTransaction.category_id.in_(category_ids))
        if excluded_category_ids:
            statement = statement.where(
                or_(
                    LedgerTransaction.category_id.is_(None),
                    LedgerTransaction.category_id.not_in(excluded_category_ids),
                )
            )
        if account_id is not None:
            statement = statement.join(Posting).where(Posting.account_id == account_id)
        if cursor_time is not None and cursor_id is not None:
            statement = statement.where(
                (LedgerTransaction.occurred_at < cursor_time)
                | (
                    (LedgerTransaction.occurred_at == cursor_time)
                    & (LedgerTransaction.id < cursor_id)
                )
            )
        statement = statement.order_by(
            LedgerTransaction.occurred_at.desc(), LedgerTransaction.id.desc()
        ).limit(limit + 1)
        return list((await self.session.scalars(statement)).unique().all())

    async def period_ledger_page(
        self,
        *,
        occurred_from: datetime,
        occurred_to_exclusive: datetime,
        category_id: UUID | None,
        account_id: UUID | None,
        merchant_id: UUID | None,
        source: str | None,
        cursor_time: datetime | None,
        cursor_id: UUID | None,
        limit: int,
    ) -> list[LedgerTransaction]:
        """Bounded report evidence page; every optional filter is in SQL.

        The merchant relation is intentionally an ``EXISTS`` predicate rather
        than a join so a transaction can never be duplicated by future mapping
        history changes.  Postings are select-in loaded once for the page.
        """
        statement = (
            select(LedgerTransaction)
            .where(
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.occurred_at >= occurred_from,
                LedgerTransaction.occurred_at < occurred_to_exclusive,
            )
            .options(selectinload(LedgerTransaction.postings))
        )
        if category_id is not None:
            statement = statement.where(LedgerTransaction.category_id == category_id)
        if account_id is not None:
            statement = statement.where(
                exists().where(
                    (Posting.transaction_id == LedgerTransaction.id)
                    & (Posting.account_id == account_id)
                )
            )
        if merchant_id is not None:
            statement = statement.where(
                exists().where(
                    (TransactionMerchantMapping.transaction_id == LedgerTransaction.id)
                    & (TransactionMerchantMapping.merchant_id == merchant_id)
                )
            )
        if source is not None:
            statement = statement.where(LedgerTransaction.source == source)
        if cursor_time is not None and cursor_id is not None:
            statement = statement.where(
                (LedgerTransaction.occurred_at < cursor_time)
                | (
                    (LedgerTransaction.occurred_at == cursor_time)
                    & (LedgerTransaction.id < cursor_id)
                )
            )
        statement = statement.order_by(
            LedgerTransaction.occurred_at.desc(), LedgerTransaction.id.desc()
        ).limit(limit + 1)
        return list((await self.session.scalars(statement)).unique().all())

    async def period_account_impacts(self, *, occurred_before: datetime) -> dict[UUID, int]:
        rows = await self.session.execute(
            select(Posting.account_id, func.coalesce(func.sum(Posting.amount_minor), 0))
            .join(LedgerTransaction, LedgerTransaction.id == Posting.transaction_id)
            .where(
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.occurred_at < occurred_before,
            )
            .group_by(Posting.account_id)
        )
        return {
            account_id: checked_int64(int(amount), label="period account impact")
            for account_id, amount in rows
        }

    async def period_reimbursement_claim_snapshots(
        self, *, recorded_before: datetime
    ) -> list[tuple[UUID, dict[str, object]]]:
        """Latest immutable formal claim state known by one period boundary."""
        rows = await self.session.execute(
            select(ReimbursementClaimRevision.claim_id, ReimbursementClaimRevision.snapshot)
            .where(ReimbursementClaimRevision.created_at < recorded_before)
            .distinct(ReimbursementClaimRevision.claim_id)
            .order_by(
                ReimbursementClaimRevision.claim_id,
                ReimbursementClaimRevision.created_at.desc(),
                ReimbursementClaimRevision.id.desc(),
            )
        )
        return [(claim_id, snapshot) for claim_id, snapshot in rows.tuples()]

    async def period_reimbursement_receipt_snapshots(
        self, *, recorded_before: datetime
    ) -> list[dict[str, object]]:
        """Latest immutable receipt state known by one period boundary."""
        rows = await self.session.execute(
            select(ReimbursementReceiptRevision.snapshot)
            .where(ReimbursementReceiptRevision.created_at < recorded_before)
            .distinct(ReimbursementReceiptRevision.receipt_id)
            .order_by(
                ReimbursementReceiptRevision.receipt_id,
                ReimbursementReceiptRevision.created_at.desc(),
                ReimbursementReceiptRevision.id.desc(),
            )
        )
        return list(rows.scalars())

    async def period_transaction_snapshots(
        self, *, transaction_ids: set[UUID], recorded_before: datetime
    ) -> dict[UUID, dict[str, object]]:
        """Latest transaction states formally recorded before one report end.

        Period-end reimbursement reporting must never derive historical
        eligibility from the mutable ``transactions`` row.  The JSON snapshot
        is complete enough to establish kind, amount, occurred_at and voided
        state without joining that mutable row.
        """
        if not transaction_ids:
            return {}
        rows = await self.session.execute(
            select(TransactionRevision.transaction_id, TransactionRevision.snapshot)
            .where(
                TransactionRevision.transaction_id.in_(transaction_ids),
                TransactionRevision.created_at < recorded_before,
            )
            .distinct(TransactionRevision.transaction_id)
            .order_by(
                TransactionRevision.transaction_id,
                TransactionRevision.created_at.desc(),
                TransactionRevision.id.desc(),
            )
        )
        return {transaction_id: snapshot for transaction_id, snapshot in rows.tuples()}

    async def cash_posting_page(
        self,
        *,
        occurred_from: datetime,
        occurred_to_exclusive: datetime,
        account_id: UUID | None,
        category_ids: set[UUID] | None,
        excluded_category_ids: set[UUID] | None,
        cursor_time: datetime | None,
        cursor_id: UUID | None,
        limit: int,
    ) -> list[tuple[Posting, LedgerTransaction, Account]]:
        statement = (
            select(Posting, LedgerTransaction, Account)
            .join(LedgerTransaction, LedgerTransaction.id == Posting.transaction_id)
            .join(Account, Account.id == Posting.account_id)
            .where(
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.occurred_at >= occurred_from,
                LedgerTransaction.occurred_at < occurred_to_exclusive,
                Account.kind.in_(["cash", "debit"]),
            )
        )
        if account_id is not None:
            statement = statement.where(Posting.account_id == account_id)
        if category_ids is not None:
            statement = statement.where(LedgerTransaction.category_id.in_(category_ids))
        if excluded_category_ids:
            statement = statement.where(
                or_(
                    LedgerTransaction.category_id.is_(None),
                    LedgerTransaction.category_id.not_in(excluded_category_ids),
                )
            )
        if cursor_time is not None and cursor_id is not None:
            statement = statement.where(
                (LedgerTransaction.occurred_at < cursor_time)
                | ((LedgerTransaction.occurred_at == cursor_time) & (Posting.id < cursor_id))
            )
        statement = statement.order_by(
            LedgerTransaction.occurred_at.desc(), Posting.id.desc()
        ).limit(limit + 1)
        return list((await self.session.execute(statement)).tuples())

    async def categories(self) -> dict[UUID, Category]:
        values = (await self.session.scalars(select(Category))).all()
        return {item.id: item for item in values}

    async def accounts(self) -> dict[UUID, Account]:
        values = (await self.session.scalars(select(Account))).all()
        return {item.id: item for item in values}

    async def facts_cash_page(
        self, *, cursor_sort_order: int | None, cursor_id: UUID | None, limit: int
    ) -> list[Account]:
        statement = select(Account).where(Account.kind.in_(("cash", "debit")))
        if cursor_sort_order is not None and cursor_id is not None:
            statement = statement.where(
                (Account.sort_order > cursor_sort_order)
                | ((Account.sort_order == cursor_sort_order) & (Account.id > cursor_id))
            )
        statement = statement.order_by(Account.sort_order, Account.id).limit(limit + 1)
        return list((await self.session.scalars(statement)).all())

    async def facts_cash_total(self) -> int:
        impacts = (
            select(
                Posting.account_id.label("account_id"),
                func.sum(Posting.amount_minor).label("impact"),
            )
            .join(LedgerTransaction, LedgerTransaction.id == Posting.transaction_id)
            .where(LedgerTransaction.voided_at.is_(None))
            .group_by(Posting.account_id)
            .subquery()
        )
        value = await self.session.scalar(
            select(
                func.coalesce(
                    func.sum(Account.opening_balance_minor + func.coalesce(impacts.c.impact, 0)), 0
                )
            )
            .outerjoin(impacts, impacts.c.account_id == Account.id)
            .where(Account.kind.in_(("cash", "debit")))
        )
        return checked_int64(int(value or 0), label="facts cash total")

    async def facts_credit_cycle_page(
        self, *, cursor_due_date: date | None, cursor_id: UUID | None, limit: int
    ) -> list[tuple[CreditCycle, Account]]:
        statement = select(CreditCycle, Account).join(Account, Account.id == CreditCycle.account_id)
        if cursor_due_date is not None and cursor_id is not None:
            statement = statement.where(
                (CreditCycle.due_date > cursor_due_date)
                | ((CreditCycle.due_date == cursor_due_date) & (CreditCycle.id > cursor_id))
            )
        statement = statement.order_by(CreditCycle.due_date, CreditCycle.id).limit(limit + 1)
        return list((await self.session.execute(statement)).tuples())

    async def future_credit_cycle_page(
        self,
        *,
        date_from: date,
        date_to: date,
        account_id: UUID | None,
        cursor: tuple[date, str, str, UUID] | None,
        limit: int,
    ) -> list[tuple[CreditCycle, Account, int]]:
        """Read only outstanding credit cycles, already bounded by the database.

        This deliberately mirrors ``CreditRepository.amounts`` in correlated
        aggregates so that fully repaid cycles are excluded *before* the
        keyset limit is applied.  Filtering them after a short page would make
        a later positive cycle unreachable.
        """
        direct_amount = (
            select(
                func.coalesce(
                    func.sum(
                        case(
                            (
                                LedgerTransaction.kind == "credit_purchase",
                                -Posting.amount_minor,
                            ),
                            else_=0,
                        )
                    ),
                    0,
                )
            )
            .select_from(LedgerTransaction)
            .join(Posting, Posting.transaction_id == LedgerTransaction.id)
            .where(
                LedgerTransaction.credit_cycle_id == CreditCycle.id,
                LedgerTransaction.voided_at.is_(None),
                or_(
                    LedgerTransaction.kind == "repayment",
                    ~exists().where(InstallmentLedgerLink.transaction_id == LedgerTransaction.id),
                ),
            )
            .correlate(CreditCycle)
            .scalar_subquery()
        )
        repaid_amount = (
            select(
                func.coalesce(
                    func.sum(
                        case(
                            (
                                (LedgerTransaction.kind == "repayment")
                                & (Posting.role == "destination"),
                                Posting.amount_minor,
                            ),
                            else_=0,
                        )
                    ),
                    0,
                )
            )
            .select_from(LedgerTransaction)
            .join(Posting, Posting.transaction_id == LedgerTransaction.id)
            .where(
                LedgerTransaction.credit_cycle_id == CreditCycle.id,
                LedgerTransaction.voided_at.is_(None),
                or_(
                    LedgerTransaction.kind == "repayment",
                    ~exists().where(InstallmentLedgerLink.transaction_id == LedgerTransaction.id),
                ),
            )
            .correlate(CreditCycle)
            .scalar_subquery()
        )
        installment_amount = (
            select(
                func.coalesce(
                    func.sum(InstallmentPeriod.principal_minor + InstallmentPeriod.fee_minor), 0
                )
            )
            .where(
                InstallmentPeriod.effective_cycle_id == CreditCycle.id,
                InstallmentPeriod.cancelled_at.is_(None),
            )
            .correlate(CreditCycle)
            .scalar_subquery()
        )
        remaining = (direct_amount + installment_amount - repaid_amount).label("remaining_minor")
        statement = (
            select(CreditCycle, Account, remaining)
            .join(Account, Account.id == CreditCycle.account_id)
            .where(CreditCycle.due_date.between(date_from, date_to), remaining > 0)
        )
        if account_id is not None:
            statement = statement.where(CreditCycle.account_id == account_id)
        statement = (
            statement.where(
                _future_after(
                    date_column=cast(ColumnElement[date], CreditCycle.due_date),
                    direction_column=literal("outflow"),
                    source_type="credit_cycle",
                    source_id_column=sql_cast(CreditCycle.id, String),
                    cursor=cursor,
                )
            )
            .order_by(CreditCycle.due_date, sql_cast(CreditCycle.id, String))
            .limit(limit + 1)
        )
        return list((await self.session.execute(statement)).tuples())

    async def future_cash_flow_page(
        self,
        *,
        date_from: date,
        date_to: date,
        account_id: UUID | None,
        cursor: tuple[date, str, str, UUID] | None,
        limit: int,
    ) -> list[CashFlowItem]:
        statement = select(CashFlowItem).where(
            CashFlowItem.status.in_(("expected", "confirmed")),
            CashFlowItem.direction.in_(("inflow", "outflow")),
            CashFlowItem.expected_date.between(date_from, date_to),
        )
        if account_id is not None:
            statement = statement.where(
                or_(
                    CashFlowItem.account_id == account_id,
                    CashFlowItem.destination_account_id == account_id,
                )
            )
        statement = (
            statement.where(
                _future_after(
                    date_column=cast(ColumnElement[date], CashFlowItem.expected_date),
                    direction_column=cast(ColumnElement[str], CashFlowItem.direction),
                    source_type="cash_flow_item",
                    source_id_column=sql_cast(CashFlowItem.id, String),
                    cursor=cursor,
                )
            )
            .order_by(
                CashFlowItem.expected_date,
                CashFlowItem.direction,
                sql_cast(CashFlowItem.id, String),
            )
            .limit(limit + 1)
        )
        return list((await self.session.scalars(statement)).all())

    async def future_reimbursement_page(
        self,
        *,
        date_from: date,
        date_to: date,
        account_id: UUID | None,
        cursor: tuple[date, str, str, UUID] | None,
        limit: int,
    ) -> list[FutureReimbursementRow]:
        """Return a bounded page without aggregating historical non-candidates."""
        # Reimbursement parties have no cash-account identity. An account
        # scoped timeline therefore has no eligible reimbursement candidates;
        # return before constructing aggregates rather than leaking them into
        # an account-filtered page.
        if account_id is not None:
            return []
        receipt_tx = aliased(LedgerTransaction)
        # Apply every source-independent timeline predicate before the costly
        # allocation / receipt aggregates.  In particular, the global cursor
        # tuple is applied to the party key itself, so a candidate cannot move
        # across pages just because its outstanding amount is later calculated.
        candidates = (
            select(
                ReimbursementClaim.id.label("claim_id"),
                ReimbursementParty.id.label("party_id"),
                ReimbursementParty.name.label("party_name"),
                ReimbursementParty.expected_date.label("expected_date"),
            )
            .select_from(ReimbursementParty)
            .join(ReimbursementClaim, ReimbursementClaim.id == ReimbursementParty.claim_id)
            .where(
                ReimbursementClaim.voided_at.is_(None),
                ReimbursementClaim.cancelled_at.is_(None),
                ReimbursementClaim.submitted_at.is_not(None),
                ReimbursementParty.expected_date.between(date_from, date_to),
                _future_after(
                    date_column=cast(ColumnElement[date], ReimbursementParty.expected_date),
                    direction_column=literal("inflow"),
                    source_type="reimbursement_party",
                    source_id_column=sql_cast(ReimbursementParty.id, String),
                    cursor=cursor,
                ),
            )
            .cte("future_reimbursement_candidates")
        )
        allocated_by_party = (
            select(
                ReimbursementAllocation.claim_id.label("claim_id"),
                ReimbursementAllocation.party_id.label("party_id"),
                func.sum(ReimbursementAllocation.amount_minor).label("allocated_minor"),
            )
            .join(
                candidates,
                (candidates.c.claim_id == ReimbursementAllocation.claim_id)
                & (candidates.c.party_id == ReimbursementAllocation.party_id),
            )
            .group_by(ReimbursementAllocation.claim_id, ReimbursementAllocation.party_id)
            .subquery()
        )
        received_by_party = (
            select(
                ReimbursementAllocation.claim_id.label("claim_id"),
                ReimbursementAllocation.party_id.label("party_id"),
                func.sum(ReimbursementReceiptAllocation.amount_minor).label("received_minor"),
            )
            .join(
                candidates,
                (candidates.c.claim_id == ReimbursementAllocation.claim_id)
                & (candidates.c.party_id == ReimbursementAllocation.party_id),
            )
            .join(
                ReimbursementReceiptAllocation,
                ReimbursementReceiptAllocation.allocation_id == ReimbursementAllocation.id,
            )
            .join(
                ReimbursementReceipt,
                ReimbursementReceipt.id == ReimbursementReceiptAllocation.receipt_id,
            )
            .join(receipt_tx, receipt_tx.id == ReimbursementReceipt.transaction_id)
            .where(receipt_tx.voided_at.is_(None))
            .group_by(ReimbursementAllocation.claim_id, ReimbursementAllocation.party_id)
            .subquery()
        )
        received_minor = func.coalesce(received_by_party.c.received_minor, 0)
        outstanding = (allocated_by_party.c.allocated_minor - received_minor).label(
            "outstanding_minor"
        )
        statement = (
            select(
                candidates.c.claim_id,
                candidates.c.party_id,
                candidates.c.party_name,
                candidates.c.expected_date,
                allocated_by_party.c.allocated_minor,
                received_minor,
            )
            .select_from(candidates)
            .join(
                allocated_by_party,
                (allocated_by_party.c.claim_id == candidates.c.claim_id)
                & (allocated_by_party.c.party_id == candidates.c.party_id),
            )
            .outerjoin(
                received_by_party,
                (received_by_party.c.claim_id == allocated_by_party.c.claim_id)
                & (received_by_party.c.party_id == allocated_by_party.c.party_id),
            )
            .where(outstanding > 0)
            .order_by(candidates.c.expected_date, sql_cast(candidates.c.party_id, String))
            .limit(limit + 1)
        )
        return [
            FutureReimbursementRow(
                claim_id=claim_id,
                party_id=party_id,
                party_name=party_name,
                expected_date=expected_date,
                outstanding_minor=checked_int64(
                    int(outstanding_minor), label="future reimbursement outstanding"
                ),
            )
            for claim_id, party_id, party_name, expected_date, allocated_minor, received_minor in (
                await self.session.execute(statement)
            ).all()
            if (
                outstanding_minor := checked_int64(
                    checked_int64(int(allocated_minor), label="future reimbursement allocated")
                    - checked_int64(int(received_minor), label="future reimbursement received"),
                    label="future reimbursement outstanding",
                )
            )
            > 0
        ]

    async def refunds_for_sources(self, source_ids: set[UUID]) -> list[RefundFact]:
        if not source_ids:
            return []
        source_id = case(
            (
                InstallmentLedgerLink.role == "principal_refund",
                InstallmentPlan.purchase_transaction_id,
            ),
            else_=InstallmentPlan.fee_transaction_id,
        )
        rows = await self.session.execute(
            select(source_id, LedgerTransaction.id, func.sum(Posting.amount_minor))
            .select_from(InstallmentLedgerLink)
            .join(InstallmentPlan, InstallmentPlan.id == InstallmentLedgerLink.plan_id)
            .join(
                LedgerTransaction,
                LedgerTransaction.id == InstallmentLedgerLink.transaction_id,
            )
            .join(Posting, Posting.transaction_id == LedgerTransaction.id)
            .where(
                InstallmentLedgerLink.role.in_(["principal_refund", "fee_refund"]),
                source_id.in_(source_ids),
                LedgerTransaction.voided_at.is_(None),
            )
            .group_by(source_id, LedgerTransaction.id)
        )
        return [
            RefundFact(source, refund, int(amount))
            for source, refund, amount in rows
            if source is not None
        ]

    async def reimbursement_facts(
        self, source_ids: set[UUID] | None = None
    ) -> list[ReimbursementFact]:
        receipt_tx = aliased(LedgerTransaction)
        received = func.coalesce(
            func.sum(
                case(
                    (receipt_tx.voided_at.is_(None), ReimbursementReceiptAllocation.amount_minor),
                    else_=0,
                )
            ),
            0,
        )
        statement = (
            select(
                ReimbursementAllocation.id,
                ReimbursementAllocation.transaction_id,
                ReimbursementClaim.id,
                ReimbursementParty.id,
                ReimbursementParty.name,
                ReimbursementParty.expected_date,
                ReimbursementClaim.submitted_at,
                ReimbursementClaim.cancelled_at,
                ReimbursementClaim.voided_at,
                ReimbursementAllocation.amount_minor,
                received,
            )
            .join(ReimbursementClaim, ReimbursementClaim.id == ReimbursementAllocation.claim_id)
            .join(ReimbursementParty, ReimbursementParty.id == ReimbursementAllocation.party_id)
            .outerjoin(
                ReimbursementReceiptAllocation,
                ReimbursementReceiptAllocation.allocation_id == ReimbursementAllocation.id,
            )
            .outerjoin(
                ReimbursementReceipt,
                ReimbursementReceipt.id == ReimbursementReceiptAllocation.receipt_id,
            )
            .outerjoin(receipt_tx, receipt_tx.id == ReimbursementReceipt.transaction_id)
            .group_by(
                ReimbursementAllocation.id,
                ReimbursementClaim.id,
                ReimbursementParty.id,
            )
        )
        if source_ids is not None:
            if not source_ids:
                return []
            statement = statement.where(ReimbursementAllocation.transaction_id.in_(source_ids))
        rows = await self.session.execute(statement)
        return [
            ReimbursementFact(
                allocation_id=allocation_id,
                source_transaction_id=transaction_id,
                claim_id=claim_id,
                party_id=party_id,
                party_name=party_name,
                expected_date=expected_date,
                submitted_at=submitted_at,
                cancelled_at=cancelled_at,
                claim_voided_at=claim_voided_at,
                allocated_minor=int(allocated),
                received_minor=int(received_minor),
            )
            for (
                allocation_id,
                transaction_id,
                claim_id,
                party_id,
                party_name,
                expected_date,
                submitted_at,
                cancelled_at,
                claim_voided_at,
                allocated,
                received_minor,
            ) in rows
        ]

    def _reimbursement_fact_statement(self):  # type: ignore[no-untyped-def]
        receipt_tx = aliased(LedgerTransaction)
        received = func.coalesce(
            func.sum(
                case(
                    (receipt_tx.voided_at.is_(None), ReimbursementReceiptAllocation.amount_minor),
                    else_=0,
                )
            ),
            0,
        ).label("received_minor")
        expected = case(
            (ReimbursementClaim.voided_at.is_not(None), 0),
            (ReimbursementClaim.cancelled_at.is_not(None), received),
            else_=ReimbursementAllocation.amount_minor,
        ).label("expected_minor")
        outstanding = (expected - received).label("outstanding_minor")
        return (
            select(
                ReimbursementAllocation.id.label("allocation_id"),
                ReimbursementClaim.id.label("claim_id"),
                ReimbursementParty.id.label("party_id"),
                ReimbursementParty.name.label("party_name"),
                ReimbursementParty.expected_date.label("expected_date"),
                expected,
                received,
                outstanding,
            )
            .join(ReimbursementClaim, ReimbursementClaim.id == ReimbursementAllocation.claim_id)
            .join(ReimbursementParty, ReimbursementParty.id == ReimbursementAllocation.party_id)
            .outerjoin(
                ReimbursementReceiptAllocation,
                ReimbursementReceiptAllocation.allocation_id == ReimbursementAllocation.id,
            )
            .outerjoin(
                ReimbursementReceipt,
                ReimbursementReceipt.id == ReimbursementReceiptAllocation.receipt_id,
            )
            .outerjoin(receipt_tx, receipt_tx.id == ReimbursementReceipt.transaction_id)
            .group_by(ReimbursementAllocation.id, ReimbursementClaim.id, ReimbursementParty.id)
            .having(outstanding > 0)
        )

    async def facts_reimbursement_page(
        self, *, cursor_id: UUID | None, limit: int
    ) -> list[tuple[UUID, UUID, UUID, str, date | None, int, int, int]]:
        statement = self._reimbursement_fact_statement()
        if cursor_id is not None:
            statement = statement.where(ReimbursementAllocation.id > cursor_id)
        statement = statement.order_by(ReimbursementAllocation.id).limit(limit + 1)
        return [
            (
                allocation_id,
                claim_id,
                party_id,
                party_name,
                expected_date,
                checked_int64(int(expected_minor), label="facts reimbursement expected amount"),
                checked_int64(int(received_minor), label="facts reimbursement received amount"),
                checked_int64(
                    int(outstanding_minor), label="facts reimbursement outstanding amount"
                ),
            )
            for (
                allocation_id,
                claim_id,
                party_id,
                party_name,
                expected_date,
                expected_minor,
                received_minor,
                outstanding_minor,
            ) in (await self.session.execute(statement)).all()
        ]

    async def facts_reimbursement_total(self) -> int:
        statement = self._reimbursement_fact_statement().subquery()
        value = await self.session.scalar(
            select(func.coalesce(func.sum(statement.c.outstanding_minor), 0))
        )
        return checked_int64(int(value or 0), label="facts reimbursement total")

    async def facts_completeness_counts(self) -> tuple[int, int, int, int, datetime | None, int]:
        unresolved_import_count = await self.session.scalar(
            select(func.count(StatementImport.id)).where(
                StatementImport.status.in_(
                    [
                        "created",
                        "extracting",
                        "parsing",
                        "review_required",
                        "ready_to_confirm",
                        "partially_confirmed",
                    ]
                )
            )
        )
        failed_import_count = await self.session.scalar(
            select(func.count(StatementImport.id)).where(StatementImport.status == "failed")
        )
        uncategorized_count = await self.session.scalar(
            select(func.count(LedgerTransaction.id)).where(
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.category_id.is_(None),
                LedgerTransaction.kind.in_(("expense", "credit_purchase", "installment_fee")),
            )
        )
        uncategorized_amount = await self.session.scalar(
            select(func.coalesce(func.sum(func.abs(Posting.amount_minor)), 0))
            .join(LedgerTransaction, LedgerTransaction.id == Posting.transaction_id)
            .where(
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.category_id.is_(None),
                LedgerTransaction.kind.in_(("expense", "credit_purchase", "installment_fee")),
                Posting.role.in_(("account", "source")),
            )
        )
        last_reconciled_at = await self.session.scalar(
            select(func.max(ReconciliationCheckpoint.as_of))
        )
        return (
            checked_int64(int(unresolved_import_count or 0), label="facts unresolved import count"),
            checked_int64(int(failed_import_count or 0), label="facts failed import count"),
            checked_int64(
                int(uncategorized_count or 0), label="facts uncategorized transaction count"
            ),
            checked_int64(
                int(uncategorized_amount or 0), label="facts uncategorized transaction amount"
            ),
            last_reconciled_at,
            await self.facts_open_reconciliation_difference_count(),
        )

    async def facts_open_reconciliation_difference_count(self) -> int:
        """Count latest checkpoint differences in SQL without materializing targets."""
        ranked = select(
            ReconciliationCheckpoint.id.label("id"),
            ReconciliationCheckpoint.account_id.label("account_id"),
            ReconciliationCheckpoint.credit_cycle_id.label("credit_cycle_id"),
            ReconciliationCheckpoint.actual_balance_minor.label("actual_balance_minor"),
            ReconciliationCheckpoint.as_of.label("as_of"),
            func.row_number()
            .over(
                partition_by=(
                    ReconciliationCheckpoint.target_kind,
                    ReconciliationCheckpoint.account_id,
                    ReconciliationCheckpoint.credit_cycle_id,
                ),
                order_by=(
                    ReconciliationCheckpoint.as_of.desc(),
                    ReconciliationCheckpoint.created_at.desc(),
                    ReconciliationCheckpoint.id.desc(),
                ),
            )
            .label("rank"),
        ).subquery()
        account_book = (
            select(
                Account.opening_balance_minor
                + func.coalesce(
                    func.sum(
                        case((LedgerTransaction.id.is_not(None), Posting.amount_minor), else_=0)
                    ),
                    0,
                )
            )
            .outerjoin(Posting, Posting.account_id == Account.id)
            .outerjoin(
                LedgerTransaction,
                (LedgerTransaction.id == Posting.transaction_id)
                & (LedgerTransaction.voided_at.is_(None))
                & (LedgerTransaction.occurred_at <= ranked.c.as_of),
            )
            .where(
                Account.id == ranked.c.account_id,
            )
            .group_by(Account.id)
            .correlate(ranked)
            .scalar_subquery()
        )
        direct_cycle_book = (
            select(func.coalesce(func.sum(-Posting.amount_minor), 0))
            .join(LedgerTransaction, LedgerTransaction.id == Posting.transaction_id)
            .where(
                LedgerTransaction.credit_cycle_id == ranked.c.credit_cycle_id,
                LedgerTransaction.kind.in_(("credit_purchase", "repayment")),
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.occurred_at <= ranked.c.as_of,
                Posting.role.in_(("account", "destination")),
                or_(
                    LedgerTransaction.kind == "repayment",
                    ~select(InstallmentLedgerLink.id)
                    .where(InstallmentLedgerLink.transaction_id == LedgerTransaction.id)
                    .exists(),
                ),
            )
            .correlate(ranked)
            .scalar_subquery()
        )
        installment_book = (
            select(
                func.coalesce(
                    func.sum(InstallmentPeriod.principal_minor + InstallmentPeriod.fee_minor), 0
                )
            )
            .join(InstallmentPlan, InstallmentPlan.id == InstallmentPeriod.plan_id)
            .join(
                LedgerTransaction,
                LedgerTransaction.id == InstallmentPlan.purchase_transaction_id,
            )
            .where(
                InstallmentPeriod.effective_cycle_id == ranked.c.credit_cycle_id,
                InstallmentPeriod.cancelled_at.is_(None),
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.occurred_at <= ranked.c.as_of,
            )
            .correlate(ranked)
            .scalar_subquery()
        )
        cycle_book = direct_cycle_book + installment_book
        credit_account_book = (
            select(
                Account.opening_balance_minor
                - func.coalesce(
                    func.sum(
                        case((LedgerTransaction.id.is_not(None), Posting.amount_minor), else_=0)
                    ),
                    0,
                )
            )
            .outerjoin(Posting, Posting.account_id == Account.id)
            .outerjoin(
                LedgerTransaction,
                (LedgerTransaction.id == Posting.transaction_id)
                & (LedgerTransaction.voided_at.is_(None))
                & (LedgerTransaction.occurred_at <= ranked.c.as_of),
            )
            .where(
                Account.id == ranked.c.account_id,
            )
            .group_by(Account.id)
            .correlate(ranked)
            .scalar_subquery()
        )
        # Credit account checkpoints reverse posting polarity.
        book_balance = case(
            (
                ranked.c.credit_cycle_id.is_not(None),
                cycle_book,
            ),
            (
                select(Account.kind)
                .where(Account.id == ranked.c.account_id)
                .correlate(ranked)
                .scalar_subquery()
                == "credit",
                credit_account_book,
            ),
            else_=account_book,
        )
        value = await self.session.scalar(
            select(func.count())
            .select_from(ranked)
            .where(
                ranked.c.rank == 1,
                ranked.c.actual_balance_minor != func.coalesce(book_balance, 0),
            )
        )
        return checked_int64(int(value or 0), label="facts open reconciliation difference count")

    async def credit_cycles(self) -> list[CreditCycle]:
        return list(
            (
                await self.session.scalars(
                    select(CreditCycle).order_by(CreditCycle.due_date, CreditCycle.id)
                )
            ).all()
        )

    async def credit_cycle_amounts(self, cycle_ids: list[UUID]) -> dict[UUID, tuple[int, int]]:
        from fiscal_api.repositories.credit import CreditRepository

        return await CreditRepository(self.session).amounts(cycle_ids)

    async def account_impacts(self, account_ids: list[UUID]) -> dict[UUID, int]:
        from fiscal_api.repositories.credit import CreditRepository

        return await CreditRepository(self.session).account_impacts(account_ids)

    async def installment_periods(
        self,
    ) -> list[tuple[InstallmentPeriod, InstallmentPlan, CreditCycle, LedgerTransaction]]:
        rows = await self.session.execute(
            select(InstallmentPeriod, InstallmentPlan, CreditCycle, LedgerTransaction)
            .join(InstallmentPlan, InstallmentPlan.id == InstallmentPeriod.plan_id)
            .join(CreditCycle, CreditCycle.id == InstallmentPeriod.effective_cycle_id)
            .join(
                LedgerTransaction,
                LedgerTransaction.id == InstallmentPlan.purchase_transaction_id,
            )
            .where(
                InstallmentPeriod.cancelled_at.is_(None),
                InstallmentPeriod.settled_early_at.is_(None),
                LedgerTransaction.voided_at.is_(None),
            )
            .options(selectinload(InstallmentPlan.periods))
            .order_by(CreditCycle.statement_date, InstallmentPeriod.id)
        )
        return list(rows.unique().tuples())
