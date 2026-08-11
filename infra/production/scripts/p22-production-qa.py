#!/usr/bin/env python3
"""Run the single permitted P22 production category receipt QA via stdin bearer key."""
from __future__ import annotations

import json
import sys
import argparse
from datetime import datetime, timezone
from urllib.error import HTTPError
from urllib.request import Request, urlopen

BASE_URL = "https://fiscal.linotsai.top/api/v1"
EXPECTED_SCOPES = {
    "ledger", "reports", "attention", "ai", "accounts", "credit", "reimbursements", "cash_flow", "reconciliation"
}


def request(key: str, path: str, method: str = "GET", body: dict[str, object] | None = None):
    data = None if body is None else json.dumps(body).encode()
    return urlopen(Request(BASE_URL + path, data=data, method=method, headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"}), timeout=20)


def main(argv: list[str] | None = None) -> None:
    argparse.ArgumentParser(description="Run the single stdin-only P22 production QA receipt check").parse_args(argv)
    key = sys.stdin.readline().strip()
    if not key:
        raise SystemExit("missing bearer key on standard input")
    name = "P22 production QA " + datetime.now(timezone.utc).strftime("%Y%m%dt%H%M%Sz")
    created: dict[str, object] | None = None
    delete_error: Exception | None = None
    try:
        with request(key, "/categories", "POST", {"name": name, "direction": "expense", "icon": "tag", "color_hex": "#123456"}) as response:
            created = json.load(response)
            revision = response.headers.get("X-Fiscal-Data-Revision")
            scopes = response.headers.get("X-Fiscal-Affected-Scopes")
        if revision != "1" or scopes is None or set(scopes.split(",")) != EXPECTED_SCOPES:
            raise RuntimeError("create receipt is missing or invalid")
        with request(key, f"/categories/{created['id']}?expected_version={created['version']}", "DELETE") as response:
            revision = response.headers.get("X-Fiscal-Data-Revision")
            scopes = response.headers.get("X-Fiscal-Affected-Scopes")
        if revision != "2" or scopes is None or set(scopes.split(",")) != EXPECTED_SCOPES:
            raise RuntimeError("delete receipt is missing or invalid")
        print("production_qa=status=create201/delete204 revisions=1,2 scopes=full9 cleanup=complete")
    finally:
        if created is not None:
            try:
                with request(key, f"/categories/{created['id']}?expected_version={created['version']}", "DELETE"):
                    pass
            except HTTPError as error:
                if error.code != 404:
                    delete_error = error
            except Exception as error:
                delete_error = error
        if delete_error is not None:
            raise RuntimeError("production QA cleanup delete failed") from delete_error


if __name__ == "__main__":
    main(sys.argv[1:])
