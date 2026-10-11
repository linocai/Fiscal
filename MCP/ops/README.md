# Fiscal remote MCP on HZ

This deployment puts only the MCP gateway on HZ. The Fiscal API and PostgreSQL
remain on NB and stay the single ledger writer:

```text
Agent -> https://mcp.fiscal.linotsai.top/mcp -> HZ Nginx
      -> 127.0.0.1:8050 fiscal-mcp.service
      -> https://fiscal.linotsai.top/api/v1 (NB Fiscal API)
```

The gateway accepts JSON-RPC POST requests with an `Authorization: Bearer ...`
header, returns MCP JSON-RPC responses, and keeps the existing tool/scope
contract. It also exposes an unauthenticated `/health` liveness response. Port
8050 remains loopback-only; do not add a public firewall rule for it.

## Build the HZ release

The HZ host should receive a committed MCP tree under `/opt/fiscal-mcp/current`
with an isolated Python 3.12 environment. The exact release transfer and
package installation are operator actions; never copy the env file into Git:

```sh
groupadd --system fiscal-mcp 2>/dev/null || true
useradd --system --gid fiscal-mcp --home-dir /opt/fiscal-mcp --shell /usr/sbin/nologin fiscal-mcp 2>/dev/null || true
install -d -o fiscal-mcp -g fiscal-mcp -m 0750 /opt/fiscal-mcp/current
python3.12 -m venv /opt/fiscal-mcp/current/.venv
/opt/fiscal-mcp/current/.venv/bin/pip install --no-cache-dir /opt/fiscal-mcp/current
install -o root -g fiscal-mcp -m 0640 ops/fiscal-mcp.env.example /etc/fiscal/mcp.env
# Edit /etc/fiscal/mcp.env on HZ without printing it.
```

Run `MCP/scripts/preflight.py --env-file /etc/fiscal/mcp.env --target production`
from the release tree before installing the unit. The check validates shape and
policy only; it does not call NB or prove a token.

Install the service without starting it first, then verify its local health:

```sh
install -o root -g root -m 0644 ops/systemd/fiscal-mcp.service /etc/systemd/system/
systemctl daemon-reload
systemctl cat fiscal-mcp.service >/dev/null
systemctl enable --now fiscal-mcp.service
curl --fail --show-error http://127.0.0.1:8050/health
```

Do not start the service until `/etc/fiscal/mcp.env` contains the NB backend URL
and backend access token. Connect the unit to HZ's existing alerting separately
if service-failure notifications are required.

## HZ Nginx and DNS

Use a separate Nginx site from existing HZ workloads. Before enabling TLS,
create the DNS A record `mcp.fiscal.linotsai.top -> 118.178.122.194`, install
the HTTP challenge site, obtain the certificate, then install the full
`nginx/fiscal-mcp.conf` file. Always run `nginx -t` before reload. The existing
80/443 firewall policy is sufficient; do not expose 8050.

Install `certbot/50-fiscal-mcp-nginx-reload` under
`/etc/letsencrypt/renewal-hooks/deploy/` so a renewed MCP certificate reloads
Nginx after Certbot has replaced the symlinks. The hook is lineage-scoped and
does not touch other sites.

The upstream NB backend remains `https://fiscal.linotsai.top/api/v1` in the MCP
env file. A failed gateway must not cause DNS to point at NB or HZ to become a
second ledger writer; restart/rollback only the MCP service and its immutable
release.

## Multi-terminal Agent configuration

Every terminal uses the same URL and an Agent key with the smallest required
scopes. Start with:

```text
read:reports,read:ledger,stage:imports,export:reports
```

Keep `commit:imports` disabled until the first real weekly/monthly loop has
been accepted. Each Agent client should keep the key in its own secret store;
do not place it in a shared public config, URL, browser localStorage, or chat
history. The generic connection shape is in `clients/fiscal-remote-mcp.example.json`;
client-specific JSON/YAML syntax may differ.

After configuring a terminal, verify `initialize`, `tools/list`, a monthly
report read, and a harmless ledger search. Then use one staged batch to verify
the full confirmation path. The key is sent on every HTTP request; a gateway
restart clears only its in-memory audit ring, not Fiscal ledger data.

## HZ operator acceptance

The following are deliberately left for the HZ operator: DNS/TLS issuance,
Nginx regression against existing hosts, service restart/readiness, NB API
authentication, CORS if the Web console calls `/mcp` from a browser, key
rotation/revocation, and one real bill batch. These files are installation
inputs and do not prove that HZ or NB has changed.
