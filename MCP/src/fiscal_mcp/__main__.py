"""Start the Fiscal MCP stdio server."""

from __future__ import annotations

import asyncio

from .server import build_default_server, run_stdio


def main() -> None:
    asyncio.run(run_stdio(build_default_server()))


if __name__ == "__main__":
    main()

