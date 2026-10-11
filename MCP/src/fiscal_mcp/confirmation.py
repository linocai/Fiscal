"""Confirmation credential boundary for batch commits."""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
from typing import Protocol

from .errors import FiscalMCPError


class ConfirmationVerifier(Protocol):
    def verify(self, token: str, *, batch_id: str, expected_version: int) -> None: ...


class HMACConfirmationVerifier:
    """Verify short-lived web-issued credentials without storing plaintext.

    Token format is ``v1.<batch_id>.<version>.<base64url signature>``.  The
    web console can mint the same format with :meth:`mint`; a production
    deployment should rotate the secret through its secret manager and add
    expiry/audience claims around this boundary.
    """

    def __init__(self, secret: bytes | str | None) -> None:
        if isinstance(secret, str):
            secret = secret.encode("utf-8")
        self._secret = secret

    def mint(self, *, batch_id: str, expected_version: int) -> str:
        if not self._secret:
            raise FiscalMCPError("confirmation_unconfigured", "Batch confirmation is not configured.")
        body = f"v1.{batch_id}.{expected_version}"
        signature = hmac.new(self._secret, body.encode("utf-8"), hashlib.sha256).digest()
        encoded = base64.urlsafe_b64encode(signature).rstrip(b"=").decode("ascii")
        return f"{body}.{encoded}"

    def verify(self, token: str, *, batch_id: str, expected_version: int) -> None:
        if not self._secret:
            raise FiscalMCPError("confirmation_unconfigured", "Batch confirmation is not configured.")
        parts = token.split(".")
        if len(parts) != 4 or parts[0] != "v1" or parts[1] != batch_id:
            raise FiscalMCPError("invalid_confirmation", "Confirmation credential is invalid or expired.")
        try:
            version = int(parts[2])
            supplied = base64.urlsafe_b64decode(parts[3] + "=" * (-len(parts[3]) % 4))
        except (TypeError, ValueError):
            raise FiscalMCPError("invalid_confirmation", "Confirmation credential is invalid or expired.") from None
        if version != expected_version:
            raise FiscalMCPError("invalid_confirmation", "Confirmation credential is invalid or expired.")
        body = f"v1.{batch_id}.{version}"
        expected = hmac.new(self._secret, body.encode("utf-8"), hashlib.sha256).digest()
        if not hmac.compare_digest(supplied, expected):
            raise FiscalMCPError("invalid_confirmation", "Confirmation credential is invalid or expired.")


class NoopConfirmationVerifier:
    """Explicit fixture verifier; never use this in production."""

    def verify(self, token: str, *, batch_id: str, expected_version: int) -> None:
        if not token or len(token) < 16:
            raise FiscalMCPError("invalid_confirmation", "Confirmation credential is invalid or expired.")


def random_confirmation_secret() -> str:
    """Generate a development secret without emitting it to logs."""

    return secrets.token_urlsafe(32)

