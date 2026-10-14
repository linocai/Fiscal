from __future__ import annotations

import base64
import hashlib
import hmac
import unittest
from datetime import datetime, timezone

from fiscal_mcp.auth import TotpSessionRegistry, request_digest
from fiscal_mcp.contracts import Scope
from fiscal_mcp.errors import FiscalMCPError


SECRET = "JBSWY3DPEHPK3PXP"
NOW = datetime(2026, 10, 11, 4, 0, 0, tzinfo=timezone.utc)


def totp(secret: str, now: datetime) -> str:
    counter = int(now.timestamp()) // 30
    raw = base64.b32decode(secret, casefold=True)
    digest = hmac.new(raw, counter.to_bytes(8, "big"), hashlib.sha1).digest()
    number = (int.from_bytes(digest[digest[-1] & 0x0F :][:4], "big") & 0x7FFFFFFF) % 1_000_000
    return f"{number:06d}"


class TotpSessionTests(unittest.TestCase):
    def make_registry(self) -> TotpSessionRegistry:
        return TotpSessionRegistry(
            SECRET,
            default_scopes=(Scope.READ_REPORTS, Scope.READ_LEDGER, Scope.STAGE_IMPORTS, Scope.EXPORT_REPORTS),
            idle_seconds=7200,
            absolute_seconds=28800,
            operation_seconds=1800,
            challenge_seconds=600,
        )

    def test_session_challenge_approval_and_poll(self) -> None:
        registry = self.make_registry()
        challenge, poll_token = registry.create_challenge(kind="session", label="test-agent", now=NOW)
        self.assertEqual(registry.poll(challenge.challenge_id, poll_token, now=NOW)["status"], "pending")
        approved = registry.approve(challenge.challenge_id, totp(SECRET, NOW), source="test", now=NOW)
        self.assertIsNotNone(approved.result_token)
        result = registry.poll(challenge.challenge_id, poll_token, now=NOW)
        session_token = result["session_token"]
        self.assertEqual(result["status"], "approved")
        session = registry.resolve(session_token, Scope.READ_REPORTS, now=NOW)
        self.assertEqual(session.label, "test-agent")
        self.assertEqual(registry.session_metadata(session_token, now=NOW)["scopes"], ["export:reports", "read:ledger", "read:reports", "stage:imports"])

    def test_session_idle_and_absolute_expiry(self) -> None:
        registry = self.make_registry()
        challenge, _ = registry.create_challenge(kind="session", now=NOW)
        registry.approve(challenge.challenge_id, totp(SECRET, NOW), now=NOW)
        token = challenge.result_token
        registry.resolve(token, now=NOW.replace(second=29))
        with self.assertRaisesRegex(FiscalMCPError, "expired"):
            registry.resolve(token, now=NOW.replace(hour=12, minute=1))

    def approved_operation(self, registry: TotpSessionRegistry, arguments: dict) -> tuple[str, str, str]:
        challenge, _ = registry.create_challenge(kind="session", now=NOW)
        registry.approve(challenge.challenge_id, totp(SECRET, NOW), now=NOW)
        session_token = challenge.result_token
        digest = request_digest("fiscal_commit_import_batch", arguments)
        operation, poll = registry.create_challenge(
            kind="operation", session_token=session_token, request_digest_value=digest, now=NOW
        )
        registry.approve(operation.challenge_id, totp(SECRET, NOW), now=NOW)
        operation_token = registry.poll(operation.challenge_id, poll, now=NOW)["operation_token"]
        return session_token, operation_token, digest

    def assert_code(self, code: str, call) -> None:
        with self.assertRaises(FiscalMCPError) as caught:
            call()
        self.assertEqual(caught.exception.code, code)

    def test_operation_is_bound_to_request_and_single_use(self) -> None:
        registry = self.make_registry()
        arguments = {"batch_id": "batch-1", "expected_version": 2, "idempotency_key": "commit-1234"}
        session_token, operation_token, digest = self.approved_operation(registry, arguments)
        self.assert_code("operation_token_missing", lambda: registry.reserve_operation(None, session_token, digest, now=NOW))
        self.assert_code("operation_invalid", lambda: registry.reserve_operation("fiscal_operation_v1_unknown", session_token, digest, now=NOW))
        self.assert_code("operation_mismatch", lambda: registry.reserve_operation(operation_token, session_token, "0" * 64, now=NOW))
        grant = registry.reserve_operation(operation_token, session_token, digest, now=NOW)
        self.assert_code("operation_in_progress", lambda: registry.reserve_operation(operation_token, session_token, digest, now=NOW))
        registry.finish_operation(grant, used=True, now=NOW)
        self.assert_code("operation_used", lambda: registry.reserve_operation(operation_token, session_token, digest, now=NOW))

    def test_released_operation_can_retry_until_expiry(self) -> None:
        registry = self.make_registry()
        arguments = {"batch_id": "batch-1", "expected_version": 2, "idempotency_key": "commit-1234"}
        session_token, operation_token, digest = self.approved_operation(registry, arguments)
        grant = registry.reserve_operation(operation_token, session_token, digest, now=NOW)
        registry.finish_operation(grant, used=False)
        retry = registry.reserve_operation(operation_token, session_token, digest, now=NOW)
        self.assertIs(retry, grant)
        registry.finish_operation(retry, used=False)
        later = NOW.replace(minute=31)
        registry.resolve(session_token, now=NOW.replace(minute=30))
        self.assert_code("operation_expired", lambda: registry.reserve_operation(operation_token, session_token, digest, now=later))

    def test_commit_scope_cannot_be_session_scope(self) -> None:
        registry = self.make_registry()
        with self.assertRaisesRegex(FiscalMCPError, "write approval"):
            registry.create_challenge(kind="session", requested_scopes=[Scope.COMMIT_IMPORTS], now=NOW)


if __name__ == "__main__":
    unittest.main()
