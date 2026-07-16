#!/usr/bin/env python3
"""Send a non-secret operational failure to a configured generic JSON webhook."""

from __future__ import annotations

import json
import os
import socket
import sys
from datetime import UTC, datetime
from urllib.request import Request, urlopen


def main() -> int:
    service = sys.argv[1] if len(sys.argv) == 2 else "unknown"
    webhook = os.environ.get("FISCAL_ALERT_WEBHOOK_URL", "").strip()
    if not webhook.startswith("https://"):
        print("Fiscal notification receiver is not configured", file=sys.stderr)
        return 1

    payload = json.dumps(
        {
            "service": service,
            "state": "failed",
            "host": socket.gethostname(),
            "timestamp": datetime.now(UTC).isoformat(),
        }
    ).encode()
    request = Request(
        webhook,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=10) as response:  # noqa: S310
            if not 200 <= response.status < 300:
                raise RuntimeError("notification receiver rejected the request")
    except Exception:
        print("Fiscal failure notification could not be delivered", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
