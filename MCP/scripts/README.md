# MCP operator checks

`preflight.py` checks the shape and safety boundaries of an untracked MCP
environment file. It never contacts the API and never prints token or secret
values, so a passing result is not an acceptance test.

```sh
cp MCP/ops/fiscal-mcp.env.example /path/to/fiscal-mcp.env
# Edit the copy outside the repository, then restrict it to the Agent user.
chmod 600 /path/to/fiscal-mcp.env
python3 MCP/scripts/preflight.py --env-file /path/to/fiscal-mcp.env --target staging
```

Use `--target local` for an HTTP localhost backend or mock adapter. Staging and
production require an HTTPS `/api/v1` backend root and reject mock mode. The
check requires an explicit `/import-batches` path, loopback `/mcp`/`/health`
paths and port 8050, and validates
`commit:imports` confirmation-secret requirements, but does not prove that the
backend token, Agent key, migration, or DNS/TLS setup actually works.

After it passes, start a local stdio process with the same environment:

```sh
set -a; . /path/to/fiscal-mcp.env; set +a
PYTHONPATH=/path/to/Fiscal/MCP/src python3 -m fiscal_mcp
```

For the HZ remote gateway, the same env file is loaded by
`ops/systemd/fiscal-mcp.service`; the `fiscal-mcp-http` entry point listens on
the configured loopback port and HZ Nginx publishes only `/mcp` over HTTPS.
The Agent host supplies `Authorization: Bearer ...` on each request.
