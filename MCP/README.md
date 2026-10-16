# Fiscal Ledger MCP

This directory contains the independent Agent-facing MCP boundary for Fiscal.
It is deliberately separate from `Backend/`.  The server does not
import Fiscal's backend code or connect to its database.  It calls the existing
HTTP report/ledger/export and atomic import-batch routes through
`HttpFiscalBackendAdapter`; `MockFiscalBackendAdapter` provides a deterministic
local fixture for contract and Web work.

## Authentication model

Remote Agents do not receive a per-Agent key. They read the public Agent
instructions at `https://console.fiscal.linotsai.top/agent/`, create a session
challenge at `POST https://mcp.fiscal.linotsai.top/auth/challenges`, and send
the returned approval URL to the owner. The owner enters the current Google
Authenticator code on the approval page. The Agent polls with
`X-Fiscal-Poll-Token`, then uses `Authorization: Session <token>` for MCP
calls. The session lasts two hours after its last request and at most eight
hours; the 30-second TOTP rotation does not interrupt it.

Creating or committing a batch is split into two actions. Staging and
validation use the session. Before `fiscal_commit_import_batch`, the Agent
creates a `write_window` challenge with its session. A second Authenticator
approval opens a 30-minute write window on that session; every commit in the
window is accepted without another approval, and the gateway mints the backend
confirmation credential internally. Approvals happen on the fixed page
`/agent/approve/`, which lists pending challenges with a 4-character pairing
code the Agent relays to the owner.

The personal Fiscal API key remains a manual break-glass credential. It is not
published in discovery, not requested from Agents, and not used as an automatic
fallback. Legacy bearer keys can still be enabled for controlled compatibility
clients.

The machine-readable contract is at
`https://console.fiscal.linotsai.top/.well-known/fiscal-agent.json`.

## Run locally

From the repository root (no installation required):

```sh
PYTHONPATH=MCP/src FISCAL_MCP_USE_MOCK=1 \
  FISCAL_MCP_API_KEY='replace-with-a-local-key-32chars' \
  FISCAL_MCP_API_SCOPES='read:reports,read:ledger,stage:imports,export:reports' \
  python -m fiscal_mcp
```

The process speaks newline-delimited JSON-RPC on stdin/stdout. It implements
the MCP `initialize`, `tools/list`, `tools/call`, and `ping` methods. The local
stdio example uses a legacy bearer key; the remote HTTP gateway uses the TOTP
session flow above.

For an existing HTTP backend:

```sh
PYTHONPATH=MCP/src \
  FISCAL_BACKEND_URL='https://fiscal.example' \
  FISCAL_BACKEND_TOKEN='backend-bearer-token' \
  FISCAL_MCP_API_KEY='replace-with-a-local-key-32chars' \
  python -m fiscal_mcp
```

When `FISCAL_BACKEND_URL` points at Fiscal's `/api/v1` API root, the read tools
use the routes `/reports/v2/monthly/{period}`,
`/reports/v2/yearly/{year}`, and `/transactions`; CSV export uses the matching
`export.csv` routes. `FISCAL_BATCH_API_PATH=/import-batches` enables the atomic
batch routes `GET/POST /{batch}` and `/{batch}/{id}/validate|commit|ignore`.
When it is absent every batch operation returns `batch_api_unavailable`.

For a staging or production Agent host, copy `ops/fiscal-mcp.env.example` to an
untracked file and run the secret-free boundary check first:

```sh
python3 MCP/scripts/preflight.py \
  --env-file /path/to/fiscal-mcp.env --target staging
```

The check validates the HTTPS `/api/v1` root, explicit batch path, TOTP secret,
session scopes and lifetimes, approval URL, mock-mode policy and the independent
confirmation secret. It does not contact Fiscal or prove a token, migration,
DNS/TLS certificate or real bill flow. The package supports local stdio and the
HZ remote HTTP gateway; the Agent does not own a permanent key.

For the HZ gateway, install the service and Nginx assets in `ops/` and expose
`/mcp`, `/auth/challenges` and `/health` through HTTPS. The gateway never gives
an Agent database access.

The adapter forwards `expected_version`, `confirmation_token`, and the commit
`idempotency_key` in the commit body and repeats the idempotency key in the
`Idempotency-Key` header. It preserves backend errors and only surfaces a
`data_revision` when the response body or an explicit
`X-Fiscal-Data-Revision`/`X-Data-Revision` header supplies one. A collection
response may be either `{ "items": [...] }`, `{ "batches": [...] }`, or a
bare array; candidate fields are left untouched for the Web normalizer.

## Tool and permission contract

The stable phase-one tools are:

| Tool | Scope | Effect |
| --- | --- | --- |
| `fiscal_get_monthly_report` | `read:reports` | Read monthly report and `data_revision` |
| `fiscal_get_yearly_report` | `read:reports` | Read yearly report and `data_revision` |
| `fiscal_search_ledger` | `read:ledger` | Read paginated ledger entries |
| `fiscal_create_import_batch` | `stage:imports` | Create pending candidates only |
| `fiscal_get_import_batch` | `stage:imports` | Read candidates and validation |
| `fiscal_validate_import_batch` | `stage:imports` | Validate fields and duplicates |
| `fiscal_commit_import_batch` | `commit:imports` | Commit after explicit credential |
| `fiscal_ignore_import_batch` | `stage:imports` | Ignore while retaining audit/source fingerprint |
| `fiscal_export_report` | `export:reports` | Export CSV for a month or year |

Amounts are integer minor units (`amount_minor`).  Business dates must be
ISO-8601 and Fiscal continues to apply Asia/Shanghai rules in its backend.
`fiscal_create_import_batch` requires an original-content SHA-256 fingerprint,
candidate rows, and an idempotency key.  It never writes a formal transaction.
Each candidate has a caller-owned `client_id`; duplicate detection and missing
field questions are returned by validation.

Legacy bearer commits require all of:

1. `commit:imports` on the caller key;
2. the current `expected_version`;
3. an opaque confirmation credential tied to batch and version;
4. a commit `idempotency_key`.

The included `HMACConfirmationVerifier` defines the internal credential format
(`v1.<batch_id>.<version>.<signature>`). TOTP session commits do not accept a
caller-supplied confirmation token: the gateway mints it only while the
session's write window is open. It refuses all commits when
`FISCAL_MCP_CONFIRMATION_SECRET` is absent. The fixture tests may use
`NoopConfirmationVerifier`; never deploy that verifier.

## Tests

The tests use only the mock adapter and do not touch Fiscal's database or
backend.  Run from the repository root:

```sh
PYTHONPATH=MCP/src python -m unittest discover -s MCP/tests -v
```

The backend batch endpoint is additive and currently lives at
`/api/v1/import-batches`; production rollout still requires the normal migration,
secret configuration, and high-risk ledger review before enabling commit scope.

