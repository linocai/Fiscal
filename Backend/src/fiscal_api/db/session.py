from collections.abc import AsyncIterator
from typing import cast

from sqlalchemy import event, update
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import Session

from fiscal_api.db.models.revision import DataRevision


def _scope_tuple(value: object) -> tuple[str, ...]:
    if isinstance(value, (list, tuple)):
        items = cast(list[object] | tuple[object, ...], value)
        scopes: list[str] = []
        for scope in items:
            if not isinstance(scope, str):
                return ()
            scopes.append(scope)
        return tuple(scopes)
    return ()


def _formal_mutation_scopes(info: dict[str, object]) -> tuple[str, ...]:
    request = info.get("data_revision_request")
    request_scopes = getattr(getattr(request, "state", None), "data_revision_scopes", ())
    if scopes := _scope_tuple(request_scopes):
        return scopes
    return _scope_tuple(info.get("data_revision_scopes", ()))


@event.listens_for(Session, "before_flush")
def _remember_formal_change(  # pyright: ignore[reportUnusedFunction]
    session: Session, _flush_context: object, _instances: object
) -> None:
    """Record implicit and explicit flushes before ORM state is consumed.

    AsyncSession's explicit ``flush`` override is not called when a synchronous
    ORM query triggers autoflush.  The sync-session event is therefore the
    single boundary that preserves the formal-write receipt contract.
    """
    scopes = _formal_mutation_scopes(session.info)
    if (
        scopes
        and not session.info.get("data_revision_receipt_issued")
        and (session.new or session.deleted or session.dirty)
    ):
        session.info["data_revision_has_change"] = True


class FiscalAsyncSession(AsyncSession):
    """Adds the P22 data revision inside an already-open formal write transaction.

    API dependencies set ``data_revision_scopes`` only for formal data routes.
    The increment is therefore part of exactly the same commit as the write; a
    failed commit rolls both back. Operator/authentication commits intentionally
    have no scopes and do not affect user data convergence.
    """

    def _has_unit_of_work_change(self) -> bool:
        return bool(self.new or self.deleted) or any(
            self.is_modified(instance, include_collections=True) for instance in self.dirty
        )

    def _formal_mutation_scopes(self) -> tuple[str, ...]:
        """Resolve scopes at commit time, after every FastAPI dependency ran.

        Authentication can acquire the shared session before a route-level
        ``formal_mutation`` dependency sets the request scopes. Looking only at
        session construction would make that valid production ordering silently
        miss the receipt. The legacy session-info value keeps direct service
        callers compatible, while API requests use their current request state.
        """
        return _formal_mutation_scopes(self.info)

    async def flush(self, objects: object | None = None) -> None:
        if (
            self._formal_mutation_scopes()
            and not self.info.get("data_revision_receipt_issued")
            and self._has_unit_of_work_change()
        ):
            # A service commonly flushes before its final commit; remember the
            # change while it is still visible in the ORM unit of work.
            self.info["data_revision_has_change"] = True
        await super().flush(objects)  # type: ignore[arg-type]

    async def rollback(self) -> None:
        await super().rollback()
        self.info.pop("data_revision_has_change", None)

    async def commit(self) -> None:
        scopes = self._formal_mutation_scopes()
        revision: int | None = None
        has_formal_change = self._has_unit_of_work_change() or bool(
            self.info.get("data_revision_has_change")
        )
        if scopes and not self.info.get("data_revision_receipt_issued") and has_formal_change:
            revision = await self.scalar(
                update(DataRevision)
                .where(DataRevision.id == 1)
                .values(revision=DataRevision.revision + 1)
                .returning(DataRevision.revision)
            )
            if revision is None:
                raise RuntimeError("data_revision singleton is missing")
        await super().commit()
        if revision is not None:
            self.info["data_revision_receipt_issued"] = True
            self.info.pop("data_revision_has_change", None)
            self.info["committed_data_revision"] = revision
            request = self.info.get("data_revision_request")
            if request is not None:
                request.state.data_revision = revision
                request.state.data_revision_scopes = scopes


def create_engine(database_url: str) -> AsyncEngine:
    return create_async_engine(database_url, pool_pre_ping=True)


def create_session_factory(engine: AsyncEngine) -> async_sessionmaker[FiscalAsyncSession]:
    return async_sessionmaker(engine, class_=FiscalAsyncSession, expire_on_commit=False)


async def session_scope(
    factory: async_sessionmaker[AsyncSession],
) -> AsyncIterator[AsyncSession]:
    async with factory() as session:
        yield session
