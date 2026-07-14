# Fiscal P1 Contracts

> Status: construction baseline
> Authority: `PROJECT_PLAN.md` remains the product and phase authority. This document narrows P1 implementation details only.

## Scope

P1 establishes a runnable backend, native iOS 26/macOS 26 application shells, a shared client foundation, and the overview visual baseline.

The client connects to a real system-status API. Financial figures shown on the P1 overview come from debug-only preview fixtures; P1 does not create account, category, transaction, posting, credit-cycle, installment, reimbursement, or AI proposal persistence.

## Platform baseline

- Minimum deployment targets: iOS 26 and macOS 26.
- Current verified toolchain: Xcode 26.6 and Swift 6.3.3.
- Swift 6 strict concurrency is enabled.
- Prefer SwiftUI, Observation, async/await, `Task`, actors, Swift Testing, and current Foundation APIs.
- Do not introduce compatibility branches or back-deployment code for systems older than 26.

## Money and currency

- The only currency is CNY.
- Server-side financial values use `Decimal`; future PostgreSQL columns use `NUMERIC(18, 2)`.
- Swift financial values use `Decimal`; `Double` is not an accepted money representation.
- JSON money values are two-decimal strings, for example `"38642.15"`.
- User-facing negative values use the ASCII hyphen (`-`), not U+2212.
- Financial figures use tabular digits.

P1 system endpoints do not expose financial amounts. These rules are nevertheless implemented and tested as shared foundations for later phases.

## Date and time

- Stored and transported instants are timezone-aware UTC timestamps in RFC 3339 format.
- The fixed business timezone is `Asia/Shanghai`.
- A business date is represented as `YYYY-MM-DD` and must not be shifted through an implicit UTC conversion.
- Server responses publish both the server instant and business timezone where relevant.

## Request identity and logging

- The server accepts an incoming `X-Request-ID` or generates one.
- Every response returns `X-Request-ID`.
- Structured logs include request ID, method, path, status, and duration.
- Logs must not contain Authorization headers, device tokens, database credentials, Keychain values, or future AI source text.

## Error envelope

All expected API errors use this shape:

```json
{
  "error": {
    "code": "device_token_invalid",
    "message": "设备访问密钥无效",
    "details": null,
    "request_id": "6f8c41c9-32fb-46d3-8f42-53e6b0fa0919"
  }
}
```

The `message` is safe to show to the single user. Clients branch on `code`, not localized text.

## P1 API

All routes are under `/api/v1`.

### `GET /health/live`

- Authentication: none.
- Purpose: prove that the API process can serve requests.
- Must not query PostgreSQL.
- Success: HTTP 200.

```json
{
  "status": "live"
}
```

### `GET /health/ready`

- Authentication: none in P1; infrastructure exposure can be restricted at the proxy/network layer.
- Purpose: prove that the API and PostgreSQL are ready together.
- Executes a minimal database readiness query such as `SELECT 1`.
- Success: HTTP 200.
- Database unavailable: HTTP 503 with the standard error envelope and code `database_unavailable`.

```json
{
  "status": "ready",
  "database": "ready"
}
```

### `GET /system/status`

- Authentication: `Authorization: Bearer <device-token>`.
- P1 compares the configured bootstrap token (or configured digest) in constant time.
- P1 does not create a user table or device-token lifecycle database.
- Success: HTTP 200.

```json
{
  "service": "fiscal-api",
  "version": "0.1.0",
  "environment": "local",
  "status": "operational",
  "database": "ready",
  "currency": "CNY",
  "business_timezone": "Asia/Shanghai",
  "timestamp": "2026-07-14T08:00:00Z"
}
```

Authentication failures:

- Missing credentials: HTTP 401, `authentication_required`.
- Invalid credentials: HTTP 401, `invalid_device_token`.

The response includes `WWW-Authenticate: Bearer` without echoing credentials.

## Client configuration

- API base URL is provided by build configuration, never embedded as a production secret.
- The device token is stored in Keychain, not source code, `UserDefaults`, logs, or screenshots.
- Debug/preview code may use an in-memory token store, clearly separated from live builds.
- Local and staging URLs are selected by build configuration.

## Connection state model

Both Apple platforms share the same semantic states:

| State | Meaning | Required presentation |
|---|---|---|
| idle | No request has started | Quiet neutral status |
| loading | A status request is active | Non-blocking progress, no false success |
| connected | Status response and token are valid | Green synchronized/online status |
| unauthorized | Token is missing or rejected | Clear device-key action/error |
| offline | Network path is unavailable | Offline wording distinct from authorization |
| failure | Server, decoding, Keychain, or compatibility failure | Stable Chinese explanation and retry |

The client must additionally distinguish API process availability from database readiness during QA, even if the overview only consumes `/system/status`.

## Overview fixture boundary

`OverviewSnapshot` fixtures may contain sample accounts, transactions, categories, cash-flow events, and aggregate display values solely to reproduce the visual contract.

Fixtures must:

- live under preview/debug/test support;
- be named as fixtures or samples;
- never be returned by the live repository;
- never be persisted as formal ledger data;
- include populated, empty, and long-content variants;
- use `Decimal` for displayed money.

## P1 non-applicable write lifecycle

The project-wide phase loop asks every phase to verify create, view, edit, delete/undo, and error states. P1 contains no formal financial write object, so create, edit, delete, and undo are explicitly not applicable. It is prohibited to add incomplete account or transaction endpoints merely to satisfy that checklist mechanically.

## Security boundary

P1 provides HTTPS deployment scaffolding, Keychain storage, and a bootstrap device-token check. It does not claim end-to-end encryption and does not expose login/logout UI. Token issuance, rotation, revocation, rate limiting, backup recovery, and production monitoring remain P11 work.
