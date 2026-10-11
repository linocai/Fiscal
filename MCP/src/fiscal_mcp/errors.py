"""Errors exposed by the Fiscal MCP boundary.

The MCP layer deliberately translates internal/backend failures to a small,
stable set of public error codes.  The server never returns database details.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(slots=True)
class FiscalMCPError(Exception):
    """A safe, serialisable error at the MCP boundary."""

    code: str
    message: str
    details: dict[str, Any] | None = None

    def __post_init__(self) -> None:
        Exception.__init__(self, self.message)

    def as_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {"code": self.code, "message": self.message}
        if self.details:
            result["details"] = self.details
        return result


def invalid_params(message: str, *, field: str | None = None) -> FiscalMCPError:
    details = {"field": field} if field else None
    return FiscalMCPError("invalid_params", message, details)


def missing_scope(scope: str) -> FiscalMCPError:
    return FiscalMCPError("insufficient_scope", f"This operation requires scope {scope!r}.", {"scope": scope})

