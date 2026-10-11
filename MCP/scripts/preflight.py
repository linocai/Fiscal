#!/usr/bin/env python3
"""Check an MCP runtime environment without contacting Fiscal or printing secrets.

This is a shape and boundary check for an operator's local environment file.
It deliberately does not call the backend, create a key, run a migration, or
prove that an access token is valid. Those are the operator's acceptance steps.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Mapping
from urllib.parse import urlparse

ALLOWED_SCOPES = {
    "read:reports",
    "read:ledger",
    "stage:imports",
    "commit:imports",
    "export:reports",
}
PLACEHOLDER_MARKERS = ("change_me", "replace-with", "example", "your_", "<", ">")


class ConfigError(ValueError):
    """A configuration value is missing, unsafe, or inconsistent."""


def read_env_file(path: Path) -> dict[str, str]:
    """Read the simple KEY=VALUE subset used by the checked-in examples."""

    values: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ConfigError(f"{path}:{line_number}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key or any(character.isspace() for character in key):
            raise ConfigError(f"{path}:{line_number}: invalid variable name")
        if value and value[0] in {"'", '"'}:
            quote = value[0]
            if len(value) < 2 or value[-1] != quote:
                raise ConfigError(f"{path}:{line_number}: unterminated quoted value")
            value = value[1:-1]
        values[key] = value
    return values


def _is_placeholder(value: str) -> bool:
    lowered = value.strip().lower()
    return not lowered or any(marker in lowered for marker in PLACEHOLDER_MARKERS)


def _required(values: Mapping[str, str], key: str, *, minimum: int = 1) -> str:
    value = values.get(key, "").strip()
    if len(value) < minimum or _is_placeholder(value):
        raise ConfigError(f"{key} must be set to a non-placeholder value (minimum {minimum} characters)")
    return value


def validate(values: Mapping[str, str], *, target: str) -> dict[str, str]:
    """Validate values and return a secret-free summary."""

    mock_enabled = values.get("FISCAL_MCP_USE_MOCK", "").strip().lower() in {"1", "true", "yes", "on"}
    if mock_enabled and target in {"staging", "production"}:
        raise ConfigError("FISCAL_MCP_USE_MOCK must be disabled for staging/production")

    parsed = None
    if not mock_enabled:
        raw_url = _required(values, "FISCAL_BACKEND_URL")
        parsed = urlparse(raw_url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ConfigError("FISCAL_BACKEND_URL must be an absolute HTTP(S) URL")
        if parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ConfigError("FISCAL_BACKEND_URL must not contain credentials, query, or fragment")
        if target in {"staging", "production"} and parsed.scheme != "https":
            raise ConfigError("FISCAL_BACKEND_URL must use HTTPS for staging/production")
        if parsed.path.rstrip("/") != "/api/v1":
            raise ConfigError("FISCAL_BACKEND_URL must point at the /api/v1 API root")
        _required(values, "FISCAL_BACKEND_TOKEN", minimum=16)

    _required(values, "FISCAL_MCP_API_KEY", minimum=16)
    batch_path = values.get("FISCAL_BATCH_API_PATH", "").strip()
    if not mock_enabled and batch_path != "/import-batches":
        raise ConfigError("FISCAL_BATCH_API_PATH must be /import-batches")

    http_path = values.get("FISCAL_MCP_HTTP_PATH", "/mcp").strip()
    if http_path != "/mcp":
        raise ConfigError("FISCAL_MCP_HTTP_PATH must be /mcp for the HZ Nginx contract")
    health_path = values.get("FISCAL_MCP_HEALTH_PATH", "/health").strip()
    if health_path != "/health":
        raise ConfigError("FISCAL_MCP_HEALTH_PATH must be /health for the HZ Nginx contract")
    bind_host = values.get("FISCAL_MCP_BIND_HOST", "127.0.0.1").strip()
    if target in {"staging", "production"} and bind_host not in {"127.0.0.1", "::1", "localhost"}:
        raise ConfigError("FISCAL_MCP_BIND_HOST must remain loopback for staging/production")
    try:
        bind_port = int(values.get("FISCAL_MCP_BIND_PORT", "8050"))
    except ValueError:
        raise ConfigError("FISCAL_MCP_BIND_PORT must be an integer") from None
    if not 1 <= bind_port <= 65535:
        raise ConfigError("FISCAL_MCP_BIND_PORT must be between 1 and 65535")
    if target in {"staging", "production"} and bind_port != 8050:
        raise ConfigError("FISCAL_MCP_BIND_PORT must be 8050 for the HZ Nginx contract")
    origins = [origin.strip() for origin in values.get("FISCAL_MCP_ALLOWED_ORIGINS", "").split(",") if origin.strip()]
    if "*" in origins:
        raise ConfigError("FISCAL_MCP_ALLOWED_ORIGINS must use exact origins, not *")

    raw_scopes = values.get("FISCAL_MCP_API_SCOPES", "")
    scopes = [scope.strip() for scope in raw_scopes.split(",") if scope.strip()]
    if not scopes:
        raise ConfigError("FISCAL_MCP_API_SCOPES must explicitly list at least one scope")
    unknown = sorted(set(scopes) - ALLOWED_SCOPES)
    if unknown:
        raise ConfigError(f"FISCAL_MCP_API_SCOPES contains unsupported scopes: {', '.join(unknown)}")
    if len(scopes) != len(set(scopes)):
        raise ConfigError("FISCAL_MCP_API_SCOPES must not contain duplicates")

    if "commit:imports" in scopes:
        _required(values, "FISCAL_MCP_CONFIRMATION_SECRET", minimum=32)
        if values.get("FISCAL_MCP_CONFIRMATION_SECRET", "") == values.get("FISCAL_BACKEND_TOKEN", ""):
            raise ConfigError("FISCAL_MCP_CONFIRMATION_SECRET must be independent from FISCAL_BACKEND_TOKEN")

    return {
        "target": target,
        "backend_url": "mock adapter" if parsed is None else f"{parsed.scheme}://{parsed.netloc}{parsed.path.rstrip('/')}",
        "batch_api_path": batch_path or "not used by mock adapter",
        "bind": f"{bind_host}:{bind_port}",
        "scopes": ",".join(scopes),
        "mock": "enabled" if mock_enabled else "disabled",
        "commit_confirmation": "configured" if "commit:imports" in scopes else "not required",
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, help="path to an untracked KEY=VALUE environment file")
    parser.add_argument(
        "--target",
        choices=("local", "staging", "production"),
        default="staging",
        help="deployment target used for HTTPS/mock policy (default: staging)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        values = read_env_file(args.env_file) if args.env_file else dict(os.environ)
        summary = validate(values, target=args.target)
    except (ConfigError, OSError) as error:
        print(f"MCP preflight failed: {error}", file=sys.stderr)
        return 1
    print("MCP preflight passed (configuration shape only; no network call made).")
    for key in ("target", "backend_url", "batch_api_path", "bind", "scopes", "mock", "commit_confirmation"):
        print(f"{key}={summary[key]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
