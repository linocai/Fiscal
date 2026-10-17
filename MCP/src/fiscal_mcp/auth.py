"""Credential and TOTP session enforcement for the Fiscal MCP boundary.

Legacy bearer keys are accepted as opaque values and only their SHA-256
fingerprints are retained. The normal remote flow uses a Google Authenticator
challenge to issue a bounded session; a second approval opens a short write
window on that session.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import base64
import secrets
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Iterable

from .contracts import Scope
from .errors import FiscalMCPError, missing_scope


def _fingerprint(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _totp_digest(secret: str, counter: int) -> bytes:
    normalized = "".join(secret.split()).upper()
    normalized += "=" * (-len(normalized) % 8)
    try:
        raw_secret = base64.b32decode(normalized, casefold=True)
    except (ValueError, base64.binascii.Error) as exc:
        raise ValueError("FISCAL_MCP_TOTP_SECRET must be base32") from exc
    return hmac.new(raw_secret, counter.to_bytes(8, "big"), hashlib.sha1).digest()


def totp_counter(secret: str | None, code: str, *, now: datetime | None = None, window: int = 1) -> int | None:
    """Return the 30-second time step a valid 6-digit TOTP code belongs to."""

    if not secret or not isinstance(code, str) or not code.isdigit() or len(code) != 6:
        return None
    current = now or datetime.now(timezone.utc)
    counter = int(current.timestamp()) // 30
    try:
        for offset in range(-window, window + 1):
            digest = _totp_digest(secret, counter + offset)
            number = (int.from_bytes(digest[digest[-1] & 0x0F :][:4], "big") & 0x7FFFFFFF) % 1_000_000
            if hmac.compare_digest(f"{number:06d}", code):
                return counter + offset
    except ValueError:
        return None
    return None


def verify_totp(secret: str | None, code: str, *, now: datetime | None = None, window: int = 1) -> bool:
    """Verify a Google Authenticator-compatible 6-digit TOTP code."""

    return totp_counter(secret, code, now=now, window=window) is not None


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
    write_until: datetime | None = None

    def usable(self, now: datetime, idle_seconds: int) -> bool:
        return now < self.absolute_expires_at and now < self.last_seen_at + timedelta(seconds=idle_seconds)

    def as_metadata(self, *, now: datetime, idle_seconds: int) -> dict[str, object]:
        idle_expires_at = self.last_seen_at + timedelta(seconds=idle_seconds)
        write_open = self.write_until is not None and now < self.write_until
        return {
            "session_expires_at": min(idle_expires_at, self.absolute_expires_at).isoformat(),
            "absolute_expires_at": self.absolute_expires_at.isoformat(),
            "write_window_expires_at": self.write_until.isoformat() if write_open and self.write_until else None,
            "scopes": sorted(scope.value for scope in self.scopes),
            "label": self.label,
        }


@dataclass(slots=True)
class AuthChallenge:
    challenge_id: str
    poll_fingerprint: str
    kind: str
    scopes: frozenset[Scope]
    label: str
    intent: str
    pairing_code: str
    session_fingerprint: str | None
    source: str
    created_at: datetime
    expires_at: datetime
    result_token: str | None = None
    approved_at: datetime | None = None
    failures: int = 0


PAIRING_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
# Anonymous session requests are bounded per source and overall; write-window
# requests are bounded by sessions (one pending per session) so an anonymous
# flood can never block an Agent's write approval.
MAX_PENDING_SESSION_CHALLENGES = 20
MAX_PENDING_PER_SOURCE = 2
MAX_FAILED_PER_SOURCE = 5
# A guessed session approval would hand the guesser a session, so session
# challenges get a global budget and are withdrawn after a few wrong codes.
# A write-window approval only ever opens the window for the Agent session that
# requested it, so guessing gains nothing; it keeps the per-source limit only and
# can be neither withdrawn nor blocked by anyone else's wrong codes.
MAX_FAILED_GLOBAL = 30
MAX_FAILED_PER_CHALLENGE = 5
WRITE_WINDOW_KINDS = {"write_window", "operation"}  # "operation" is the pre-Build54 name


class TotpSessionRegistry:
    """In-memory TOTP challenge, session and write-window boundary."""

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
        self._challenges: dict[str, AuthChallenge] = {}
        self._failed_attempts: dict[str, list[datetime]] = {}
        self._failed_global: list[datetime] = []
        # RFC 6238 §5.2: a code's time step is accepted once; later steps only.
        self._last_totp_counter: int | None = None

    @property
    def configured(self) -> bool:
        return self.secret is not None

    @staticmethod
    def _token() -> str:
        return f"fiscal_session_v1_{secrets.token_urlsafe(32)}"

    @staticmethod
    def _challenge_token() -> str:
        return f"fiscal_challenge_v1_{secrets.token_urlsafe(24)}"

    def _check_rate(self, source: str, now: datetime, *, anonymous: bool) -> None:
        cutoff = now - timedelta(minutes=5)
        attempts = [value for value in self._failed_attempts.get(source, []) if value > cutoff]
        self._failed_attempts[source] = attempts
        self._failed_global = [value for value in self._failed_global if value > cutoff]
        if len(attempts) >= MAX_FAILED_PER_SOURCE or (anonymous and len(self._failed_global) >= MAX_FAILED_GLOBAL):
            raise FiscalMCPError("auth_rate_limited", "Too many authentication attempts; try again later.")

    def _failed(self, source: str, now: datetime, *, anonymous: bool) -> None:
        self._failed_attempts.setdefault(source, []).append(now)
        if anonymous:
            self._failed_global.append(now)

    def _scopes(self, requested: Iterable[Scope | str] | None) -> frozenset[Scope]:
        try:
            values = self.default_scopes if requested is None else frozenset(
                scope if isinstance(scope, Scope) else Scope(scope) for scope in requested
            )
        except ValueError as exc:
            raise FiscalMCPError("invalid_scope", "The requested session scope is not supported.") from exc
        if Scope.COMMIT_IMPORTS in values:
            raise FiscalMCPError("invalid_scope", "commit:imports is granted only through a write approval.")
        if not values.issubset(self.default_scopes):
            raise FiscalMCPError("invalid_scope", "The requested session scope is not enabled.")
        return values

    def _pending(self, now: datetime) -> list[AuthChallenge]:
        for challenge_id in [key for key, value in self._challenges.items() if now >= value.expires_at]:
            del self._challenges[challenge_id]
        return [value for value in self._challenges.values() if value.approved_at is None]

    def create_challenge(
        self,
        *,
        kind: str,
        requested_scopes: Iterable[Scope | str] | None = None,
        label: str = "",
        intent: str = "",
        session_token: str | None = None,
        source: str = "unknown",
        now: datetime | None = None,
    ) -> tuple[AuthChallenge, str]:
        current = now or datetime.now(timezone.utc)
        if not self.configured:
            raise FiscalMCPError("totp_unconfigured", "Authenticator approval is not configured.")
        if not isinstance(kind, str):
            raise FiscalMCPError("invalid_challenge", "Challenge kind must be session or write_window.")
        pending = self._pending(current)
        if kind in WRITE_WINDOW_KINDS:
            if not session_token:
                raise FiscalMCPError("session_required", "A live session is required to open a write window.")
            session = self.resolve(session_token, now=current)
            if Scope.STAGE_IMPORTS not in session.scopes:
                # Read-only sessions (the owner panel) can never be widened to writes.
                raise FiscalMCPError("insufficient_scope", "A read-only session cannot open a write window.", {"scope": Scope.STAGE_IMPORTS.value})
            kind = "write_window"
            scopes = frozenset({Scope.COMMIT_IMPORTS})
            session_fingerprint: str | None = session.token_fingerprint
            # One pending window request per session: a new request replaces the old one.
            for stale in [item for item in pending if item.session_fingerprint == session_fingerprint]:
                del self._challenges[stale.challenge_id]
        elif kind == "session":
            scopes = self._scopes(requested_scopes)
            session_fingerprint = None
            sessions_pending = [item for item in pending if item.kind == "session"]
            if (
                len(sessions_pending) >= MAX_PENDING_SESSION_CHALLENGES
                or sum(1 for item in sessions_pending if item.source == source) >= MAX_PENDING_PER_SOURCE
            ):
                raise FiscalMCPError("too_many_pending", "Too many approvals are waiting; try again later.")
        else:
            raise FiscalMCPError("invalid_challenge", "Challenge kind must be session or write_window.")
        challenge_id = self._challenge_token()
        poll_token = self._challenge_token()
        challenge = AuthChallenge(
            challenge_id=challenge_id,
            poll_fingerprint=_fingerprint(poll_token),
            kind=kind,
            scopes=scopes,
            label=label[:120],
            intent=intent[:500],
            pairing_code="".join(secrets.choice(PAIRING_ALPHABET) for _ in range(4)),
            session_fingerprint=session_fingerprint,
            source=source,
            created_at=current,
            expires_at=current + timedelta(seconds=self.challenge_seconds),
        )
        self._challenges[challenge_id] = challenge
        return challenge, poll_token

    def pending(self, *, now: datetime | None = None) -> list[dict[str, object]]:
        """Public, secret-free view of approvals waiting for the owner."""
        current = now or datetime.now(timezone.utc)
        return [
            {
                "challenge_id": item.challenge_id,
                "kind": item.kind,
                "client_label": item.label,
                "intent": item.intent,
                "pairing_code": item.pairing_code,
                "created_at": item.created_at.isoformat(),
                "expires_at": item.expires_at.isoformat(),
            }
            for item in sorted(self._pending(current), key=lambda value: value.created_at)
        ]

    def approve(self, challenge_id: str, code: str, *, source: str = "unknown", now: datetime | None = None) -> AuthChallenge:
        current = now or datetime.now(timezone.utc)
        challenge = self._challenges.get(challenge_id)
        if challenge is None or current >= challenge.expires_at:
            raise FiscalMCPError("challenge_expired", "This approval challenge has expired.")
        if challenge.approved_at is not None:
            return challenge
        anonymous = challenge.kind == "session"
        self._check_rate(source, current, anonymous=anonymous)
        counter = totp_counter(self.secret, code, now=current)
        if counter is None:
            self._failed(source, current, anonymous=anonymous)
            challenge.failures += 1
            if anonymous and challenge.failures >= MAX_FAILED_PER_CHALLENGE:
                del self._challenges[challenge.challenge_id]
                raise FiscalMCPError("challenge_expired", "Too many wrong codes; this request was withdrawn. Ask the Agent to request again.")
            raise FiscalMCPError("invalid_totp", "The Authenticator code is invalid or expired.")
        if self._last_totp_counter is not None and counter <= self._last_totp_counter:
            raise FiscalMCPError("totp_reused", "This Authenticator code was already used; wait for the next code.")
        if challenge.kind == "session":
            challenge.result_token = self._issue_session(challenge.scopes, challenge.label, current)
        else:
            session = self._sessions.get(challenge.session_fingerprint or "")
            if session is None or not session.usable(current, self.idle_seconds):
                raise FiscalMCPError("session_expired", "The requesting session has expired; request a new session.")
            session.write_until = current + timedelta(seconds=self.operation_seconds)
        self._last_totp_counter = counter
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

    def require_write_window(self, token: str | None, *, now: datetime | None = None) -> AuthSession:
        current = now or datetime.now(timezone.utc)
        session = self.resolve(token, now=current)
        if session.write_until is None or current >= session.write_until:
            raise FiscalMCPError(
                "write_window_required",
                "No open write window; create a write_window challenge and have the owner approve it.",
            )
        return session

    def poll(self, challenge_id: str, poll_token: str, *, now: datetime | None = None) -> dict[str, object]:
        current = now or datetime.now(timezone.utc)
        challenge = self._challenges.get(challenge_id)
        if challenge is None or not hmac.compare_digest(challenge.poll_fingerprint, _fingerprint(poll_token)):
            raise FiscalMCPError("challenge_not_found", "The approval challenge is invalid or expired.")
        if current >= challenge.expires_at and challenge.approved_at is None:
            raise FiscalMCPError("challenge_expired", "This approval challenge has expired.")
        result: dict[str, object] = {
            "challenge_id": challenge.challenge_id,
            "status": "approved" if challenge.approved_at else "pending",
            "expires_at": challenge.expires_at.isoformat(),
            "kind": challenge.kind,
            "pairing_code": challenge.pairing_code,
        }
        if challenge.approved_at and challenge.kind == "session":
            result["session_token"] = challenge.result_token
        if challenge.approved_at and challenge.kind == "write_window":
            session = self._sessions.get(challenge.session_fingerprint or "")
            if session is not None and session.write_until is not None:
                result["write_window_expires_at"] = session.write_until.isoformat()
        return result

    def session_metadata(self, token: str, *, now: datetime | None = None) -> dict[str, object]:
        current = now or datetime.now(timezone.utc)
        session = self.resolve(token, now=current)
        return session.as_metadata(now=current, idle_seconds=self.idle_seconds)

