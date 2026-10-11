"""API-key scope enforcement for the Fiscal MCP boundary.

Keys are accepted as opaque bearer values and only their SHA-256 fingerprints
are retained by the registry.  A production key store can implement the same
protocol; this in-memory implementation keeps the first stage runnable without
touching Fiscal's existing persistence.
"""

from __future__ import annotations

import hashlib
import hmac
import os
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Iterable

from .contracts import Scope
from .errors import FiscalMCPError, missing_scope


def _fingerprint(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


@dataclass(slots=True)
class ApiKeyRecord:
    fingerprint: str
    scopes: frozenset[Scope]
    label: str = ""
    expires_at: datetime | None = None
    revoked_at: datetime | None = None
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

    def usable(self, now: datetime | None = None) -> bool:
        now = now or datetime.now(timezone.utc)
        return self.revoked_at is None and (self.expires_at is None or self.expires_at > now)

    def as_metadata(self) -> dict[str, object]:
        return {
            "fingerprint": self.fingerprint,
            "label": self.label,
            "scopes": sorted(scope.value for scope in self.scopes),
            "created_at": self.created_at.isoformat(),
            "expires_at": self.expires_at.isoformat() if self.expires_at else None,
            "revoked_at": self.revoked_at.isoformat() if self.revoked_at else None,
        }


class ApiKeyRegistry:
    """Resolve and validate bearer keys without persisting key plaintext."""

    def __init__(self) -> None:
        self._records: dict[str, ApiKeyRecord] = {}

    def register(
        self,
        key: str,
        scopes: Iterable[Scope | str],
        *,
        label: str = "",
        expires_at: datetime | None = None,
    ) -> ApiKeyRecord:
        if not isinstance(key, str) or len(key) < 16:
            raise ValueError("API keys must be at least 16 characters")
        parsed_scopes = frozenset(scope if isinstance(scope, Scope) else Scope(scope) for scope in scopes)
        record = ApiKeyRecord(_fingerprint(key), parsed_scopes, label, expires_at)
        self._records[record.fingerprint] = record
        return record

    def revoke(self, key: str) -> None:
        record = self._records.get(_fingerprint(key))
        if record is not None:
            record.revoked_at = datetime.now(timezone.utc)

    def resolve(self, key: str | None) -> ApiKeyRecord:
        if not key:
            raise FiscalMCPError("unauthorized", "A Fiscal MCP API key is required.")
        fingerprint = _fingerprint(key)
        record = self._records.get(fingerprint)
        if record is None or not hmac.compare_digest(record.fingerprint, fingerprint) or not record.usable():
            raise FiscalMCPError("unauthorized", "The Fiscal MCP API key is invalid or revoked.")
        return record

    def require(self, key: str | None, scope: Scope) -> ApiKeyRecord:
        record = self.resolve(key)
        if scope not in record.scopes:
            raise missing_scope(scope.value)
        return record

    def metadata(self) -> list[dict[str, object]]:
        return [record.as_metadata() for record in self._records.values()]

    @classmethod
    def from_environment(cls) -> tuple[ApiKeyRegistry, str | None]:
        """Load one local development key without ever logging its value.

        ``FISCAL_MCP_API_KEY`` supplies the key and
        ``FISCAL_MCP_API_SCOPES`` supplies comma-separated scopes.  A missing
        key leaves the server intentionally unauthenticated at startup and all
        tool calls fail with ``unauthorized``.
        """

        registry = cls()
        key = os.environ.get("FISCAL_MCP_API_KEY")
        if not key:
            return registry, None
        raw_scopes = os.environ.get(
            "FISCAL_MCP_API_SCOPES",
            ",".join(scope.value for scope in Scope if scope is not Scope.COMMIT_IMPORTS),
        )
        scopes = [Scope(value.strip()) for value in raw_scopes.split(",") if value.strip()]
        registry.register(key, scopes, label="environment")
        return registry, key

