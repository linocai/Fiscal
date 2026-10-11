"""Credential and TOTP session enforcement for the Fiscal MCP boundary.

Legacy bearer keys are accepted as opaque values and only their SHA-256
fingerprints are retained. The normal remote flow uses a Google Authenticator
challenge to issue a bounded session and a one-time write operation grant.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import base64
import json
import secrets
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable, Mapping

from .contracts import Scope
from .errors import FiscalMCPError, missing_scope


def _fingerprint(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def request_digest(tool: str, arguments: Mapping[str, Any]) -> str:
    """Return the stable digest bound to a write approval challenge."""

    canonical_arguments = dict(arguments)
    if tool == "fiscal_commit_import_batch":
        canonical_arguments.pop("confirmation_token", None)
    body = json.dumps({"tool": tool, "arguments": canonical_arguments}, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def _totp_digest(secret: str, counter: int) -> bytes:
    normalized = "".join(secret.split()).upper()
    normalized += "=" * (-len(normalized) % 8)
    try:
        raw_secret = base64.b32decode(normalized, casefold=True)
    except (ValueError, base64.binascii.Error) as exc:
        raise ValueError("FISCAL_MCP_TOTP_SECRET must be base32") from exc
    return hmac.new(raw_secret, counter.to_bytes(8, "big"), hashlib.sha1).digest()


def verify_totp(secret: str | None, code: str, *, now: datetime | None = None, window: int = 1) -> bool:
    """Verify a Google Authenticator-compatible 6-digit TOTP code."""

    if not secret or not isinstance(code, str) or not code.isdigit() or len(code) != 6:
        return False
    current = now or datetime.now(timezone.utc)
    counter = int(current.timestamp()) // 30
    try:
        for offset in range(-window, window + 1):
            digest = _totp_digest(secret, counter + offset)
            number = (int.from_bytes(digest[digest[-1] & 0x0F :][:4], "big") & 0x7FFFFFFF) % 1_000_000
            if hmac.compare_digest(f"{number:06d}", code):
                return True
    except ValueError:
        return False
    return False


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
        raw_scopes = os.environ.get(
            "FISCAL_MCP_API_SCOPES",
            ",".join(scope.value for scope in Scope if scope is not Scope.COMMIT_IMPORTS),
        )
        scopes = [Scope(value.strip()) for value in raw_scopes.split(",") if value.strip()]
        if key:
            registry.register(key, scopes, label="legacy-environment")
        break_glass = os.environ.get("FISCAL_MCP_BREAK_GLASS_KEY")
        if break_glass:
            registry.register(break_glass, list(Scope), label="owner-break-glass")
        return registry, key


@dataclass(slots=True)
class AuthSession:
    token_fingerprint: str
    scopes: frozenset[Scope]
    label: str
    issued_at: datetime
    last_seen_at: datetime
    absolute_expires_at: datetime

    def usable(self, now: datetime, idle_seconds: int) -> bool:
        return now < self.absolute_expires_at and now < self.last_seen_at + timedelta(seconds=idle_seconds)

    def as_metadata(self, *, now: datetime, idle_seconds: int) -> dict[str, object]:
        idle_expires_at = self.last_seen_at + timedelta(seconds=idle_seconds)
        return {
            "session_expires_at": min(idle_expires_at, self.absolute_expires_at).isoformat(),
            "absolute_expires_at": self.absolute_expires_at.isoformat(),
            "scopes": sorted(scope.value for scope in self.scopes),
            "label": self.label,
        }


@dataclass(slots=True)
class OperationGrant:
    token_fingerprint: str
    session_fingerprint: str
    scope: Scope
    request_digest: str
    expires_at: datetime
    used_at: datetime | None = None


@dataclass(slots=True)
class AuthChallenge:
    challenge_id: str
    poll_fingerprint: str
    kind: str
    scopes: frozenset[Scope]
    label: str
    intent: str
    request_digest: str | None
    session_fingerprint: str | None
    created_at: datetime
    expires_at: datetime
    result_token: str | None = None
    approved_at: datetime | None = None


class TotpSessionRegistry:
    """In-memory TOTP challenge, session and one-time operation boundary."""

    def __init__(
        self,
        secret: str | None,
        *,
        default_scopes: Iterable[Scope | str] = (),
        idle_seconds: int = 7_200,
        absolute_seconds: int = 28_800,
        operation_seconds: int = 1_800,
        challenge_seconds: int = 600,
    ) -> None:
        self.secret = secret.strip() if isinstance(secret, str) and secret.strip() else None
        if self.secret:
            _totp_digest(self.secret, 0)
        self.default_scopes = frozenset(scope if isinstance(scope, Scope) else Scope(scope) for scope in default_scopes)
        self.idle_seconds = idle_seconds
        self.absolute_seconds = absolute_seconds
        self.operation_seconds = operation_seconds
        self.challenge_seconds = challenge_seconds
        self._sessions: dict[str, AuthSession] = {}
        self._operations: dict[str, OperationGrant] = {}
        self._challenges: dict[str, AuthChallenge] = {}
        self._failed_attempts: dict[str, list[datetime]] = {}

    @property
    def configured(self) -> bool:
        return self.secret is not None

    @staticmethod
    def _token() -> str:
        return f"fiscal_session_v1_{secrets.token_urlsafe(32)}"

    @staticmethod
    def _operation_token() -> str:
        return f"fiscal_operation_v1_{secrets.token_urlsafe(32)}"

    @staticmethod
    def _challenge_token() -> str:
        return f"fiscal_challenge_v1_{secrets.token_urlsafe(24)}"

    def _check_rate(self, source: str, now: datetime) -> None:
        cutoff = now - timedelta(minutes=5)
        attempts = [value for value in self._failed_attempts.get(source, []) if value > cutoff]
        self._failed_attempts[source] = attempts
        if len(attempts) >= 5:
            raise FiscalMCPError("auth_rate_limited", "Too many authentication attempts; try again later.")

    def _failed(self, source: str, now: datetime) -> None:
        self._failed_attempts.setdefault(source, []).append(now)

    def _scopes(self, requested: Iterable[Scope | str] | None) -> frozenset[Scope]:
        values = self.default_scopes if requested is None else frozenset(
            scope if isinstance(scope, Scope) else Scope(scope) for scope in requested
        )
        if Scope.COMMIT_IMPORTS in values:
            raise FiscalMCPError("invalid_scope", "commit:imports is granted only through a write approval.")
        if not values.issubset(self.default_scopes):
            raise FiscalMCPError("invalid_scope", "The requested session scope is not enabled.")
        return values

    def create_challenge(
        self,
        *,
        kind: str,
        requested_scopes: Iterable[Scope | str] | None = None,
        label: str = "",
        intent: str = "",
        request_digest_value: str | None = None,
        session_token: str | None = None,
        now: datetime | None = None,
    ) -> tuple[AuthChallenge, str]:
        current = now or datetime.now(timezone.utc)
        if not self.configured:
            raise FiscalMCPError("totp_unconfigured", "Authenticator approval is not configured.")
        if kind not in {"session", "operation"}:
            raise FiscalMCPError("invalid_challenge", "Challenge kind must be session or operation.")
        if kind == "session":
            scopes = self._scopes(requested_scopes)
            session_fingerprint = None
            if request_digest_value:
                raise FiscalMCPError("invalid_challenge", "Session challenges do not accept a request digest.")
        else:
            if not session_token:
                raise FiscalMCPError("session_required", "A live session is required for a write approval.")
            session = self.resolve(session_token, now=current)
            scopes = frozenset({Scope.COMMIT_IMPORTS})
            session_fingerprint = session.token_fingerprint
            if not request_digest_value or len(request_digest_value) != 64:
                raise FiscalMCPError("invalid_challenge", "A write approval requires a request digest.")
        challenge_id = self._challenge_token()
        poll_token = self._challenge_token()
        challenge = AuthChallenge(
            challenge_id=challenge_id,
            poll_fingerprint=_fingerprint(poll_token),
            kind=kind,
            scopes=scopes,
            label=label[:120],
            intent=intent[:500],
            request_digest=request_digest_value,
            session_fingerprint=session_fingerprint,
            created_at=current,
            expires_at=current + timedelta(seconds=self.challenge_seconds),
        )
        self._challenges[challenge_id] = challenge
        return challenge, poll_token

    def approve(self, challenge_id: str, code: str, *, source: str = "unknown", now: datetime | None = None) -> AuthChallenge:
        current = now or datetime.now(timezone.utc)
        challenge = self._challenges.get(challenge_id)
        if challenge is None or current >= challenge.expires_at:
            raise FiscalMCPError("challenge_expired", "This approval challenge has expired.")
        if challenge.result_token:
            return challenge
        self._check_rate(source, current)
        if not verify_totp(self.secret, code, now=current):
            self._failed(source, current)
            raise FiscalMCPError("invalid_totp", "The Authenticator code is invalid or expired.")
        if challenge.kind == "session":
            token = self._issue_session(challenge.scopes, challenge.label, current)
        else:
            if not challenge.session_fingerprint or not challenge.request_digest:
                raise FiscalMCPError("invalid_challenge", "This write approval challenge is incomplete.")
            token = self._issue_operation(challenge.session_fingerprint, challenge.request_digest, current)
        challenge.result_token = token
        challenge.approved_at = current
        return challenge

    def _issue_session(self, scopes: frozenset[Scope], label: str, now: datetime) -> str:
        token = self._token()
        self._sessions[_fingerprint(token)] = AuthSession(
            token_fingerprint=_fingerprint(token),
            scopes=scopes,
            label=label,
            issued_at=now,
            last_seen_at=now,
            absolute_expires_at=now + timedelta(seconds=self.absolute_seconds),
        )
        return token

    def resolve(self, token: str | None, required_scope: Scope | None = None, *, now: datetime | None = None) -> AuthSession:
        current = now or datetime.now(timezone.utc)
        fingerprint = _fingerprint(token or "")
        session = self._sessions.get(fingerprint)
        if session is None or not session.usable(current, self.idle_seconds):
            self._sessions.pop(fingerprint, None)
            raise FiscalMCPError("session_expired", "The Fiscal session has expired; request a new approval.")
        if required_scope is not None and required_scope not in session.scopes:
            raise missing_scope(required_scope.value)
        session.last_seen_at = current
        return session

    def _issue_operation(self, session_fingerprint: str, request_digest_value: str, now: datetime) -> str:
        token = self._operation_token()
        self._operations[_fingerprint(token)] = OperationGrant(
            token_fingerprint=_fingerprint(token),
            session_fingerprint=session_fingerprint,
            scope=Scope.COMMIT_IMPORTS,
            request_digest=request_digest_value,
            expires_at=now + timedelta(seconds=self.operation_seconds),
        )
        return token

    def consume_operation(
        self,
        token: str | None,
        session_token: str,
        request_digest_value: str,
        *,
        now: datetime | None = None,
    ) -> None:
        current = now or datetime.now(timezone.utc)
        session = self.resolve(session_token, now=current)
        grant = self._operations.get(_fingerprint(token or ""))
        if grant is None or grant.used_at is not None or current >= grant.expires_at:
            raise FiscalMCPError("operation_expired", "The write approval has expired or was already used.")
        if grant.session_fingerprint != session.token_fingerprint or grant.request_digest != request_digest_value:
            raise FiscalMCPError("operation_mismatch", "The write approval does not match this request.")
        grant.used_at = current

    def poll(self, challenge_id: str, poll_token: str, *, now: datetime | None = None) -> dict[str, object]:
        current = now or datetime.now(timezone.utc)
        challenge = self._challenges.get(challenge_id)
        if challenge is None or not hmac.compare_digest(challenge.poll_fingerprint, _fingerprint(poll_token)):
            raise FiscalMCPError("challenge_not_found", "The approval challenge is invalid or expired.")
        if current >= challenge.expires_at and not challenge.result_token:
            raise FiscalMCPError("challenge_expired", "This approval challenge has expired.")
        result: dict[str, object] = {
            "challenge_id": challenge.challenge_id,
            "status": "approved" if challenge.result_token else "pending",
            "expires_at": challenge.expires_at.isoformat(),
            "kind": challenge.kind,
        }
        if challenge.result_token:
            result["session_token" if challenge.kind == "session" else "operation_token"] = challenge.result_token
        return result

    def session_metadata(self, token: str, *, now: datetime | None = None) -> dict[str, object]:
        current = now or datetime.now(timezone.utc)
        session = self.resolve(token, now=current)
        return session.as_metadata(now=current, idle_seconds=self.idle_seconds)

