from __future__ import annotations

import base64
import hashlib
import hmac
import unittest
from datetime import datetime, timezone

from datetime import timedelta

from fiscal_mcp.auth import MAX_PENDING_CHALLENGES, TotpSessionRegistry
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

    def session(self, registry: TotpSessionRegistry) -> str:
        challenge, _ = registry.create_challenge(kind="session", now=NOW)
        registry.approve(challenge.challenge_id, totp(SECRET, NOW), now=NOW)
        assert challenge.result_token is not None
        return challenge.result_token

    def assert_code(self, code: str, call) -> None:
        with self.assertRaises(FiscalMCPError) as caught:
            call()
        self.assertEqual(caught.exception.code, code)

    def test_write_window_opens_for_thirty_minutes_on_the_requesting_session(self) -> None:
        registry = self.make_registry()
        session_token = self.session(registry)
        other_token = self.session(registry)
        self.assert_code("write_window_required", lambda: registry.require_write_window(session_token, now=NOW))
        window, poll = registry.create_challenge(kind="write_window", session_token=session_token, intent="提交本周账单", now=NOW)
        self.assertEqual(registry.poll(window.challenge_id, poll, now=NOW)["status"], "pending")
        registry.approve(window.challenge_id, totp(SECRET, NOW), now=NOW)
        polled = registry.poll(window.challenge_id, poll, now=NOW)
        self.assertEqual(polled["status"], "approved")
        self.assertNotIn("session_token", polled)
        self.assertEqual(polled["write_window_expires_at"], (NOW + timedelta(minutes=30)).isoformat())
        for minute in (0, 15, 29):
            registry.require_write_window(session_token, now=NOW + timedelta(minutes=minute))
        self.assert_code("write_window_required", lambda: registry.require_write_window(other_token, now=NOW))
        self.assert_code(
            "write_window_required",
            lambda: registry.require_write_window(session_token, now=NOW + timedelta(minutes=30)),
        )
        self.assertIsNone(registry.session_metadata(session_token, now=NOW + timedelta(minutes=31))["write_window_expires_at"])

    def test_legacy_operation_kind_opens_a_window_and_requires_a_session(self) -> None:
        registry = self.make_registry()
        self.assert_code("session_required", lambda: registry.create_challenge(kind="write_window", now=NOW))
        session_token = self.session(registry)
        legacy, _ = registry.create_challenge(kind="operation", session_token=session_token, now=NOW)
        self.assertEqual(legacy.kind, "write_window")

    def test_read_only_session_cannot_open_a_write_window(self) -> None:
        registry = self.make_registry()
        challenge, _ = registry.create_challenge(kind="session", requested_scopes=[Scope.READ_REPORTS, Scope.READ_LEDGER], now=NOW)
        registry.approve(challenge.challenge_id, totp(SECRET, NOW), now=NOW)
        self.assert_code(
            "insufficient_scope",
            lambda: registry.create_challenge(kind="write_window", session_token=challenge.result_token, now=NOW),
        )

    def test_pending_list_is_secret_free_and_bounded(self) -> None:
        registry = self.make_registry()
        self.assertEqual(registry.pending(now=NOW), [])
        challenge, poll = registry.create_challenge(kind="session", label="agent", intent="整理账单", now=NOW)
        [item] = registry.pending(now=NOW)
        self.assertEqual(item["pairing_code"], challenge.pairing_code)
        self.assertRegex(challenge.pairing_code, r"^[A-Z2-9]{4}$")
        self.assertEqual(set(item), {"challenge_id", "kind", "client_label", "intent", "pairing_code", "created_at", "expires_at"})
        self.assertNotIn(poll, str(item))
        registry.approve(challenge.challenge_id, totp(SECRET, NOW), now=NOW)
        self.assertEqual(registry.pending(now=NOW), [])
        for _ in range(MAX_PENDING_CHALLENGES):
            registry.create_challenge(kind="session", now=NOW)
        self.assert_code("too_many_pending", lambda: registry.create_challenge(kind="session", now=NOW))
        later = NOW + timedelta(minutes=11)
        self.assertEqual(registry.pending(now=later), [])
        registry.create_challenge(kind="session", now=later)

    def test_commit_scope_cannot_be_session_scope(self) -> None:
        registry = self.make_registry()
        with self.assertRaisesRegex(FiscalMCPError, "write approval"):
            registry.create_challenge(kind="session", requested_scopes=[Scope.COMMIT_IMPORTS], now=NOW)


if __name__ == "__main__":
    unittest.main()
