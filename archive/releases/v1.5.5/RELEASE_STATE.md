# Fiscal v1.5.5 release state

## v1.5.5 (Build 32) — current production release

| Field | Released state |
| --- | --- |
| Scope | Repair ordinary-refresh recovery after an unknown AI-proposal deletion while retaining all Build 31 deletion and provider-failure capabilities |
| Source revision | `5bf795625673209cfa3b5d7d1f35a7dd9ca8eb01` (`fix(ai): recover unknown deletion on refresh`) |
| Backend | Production active in Ningbo at revision `3eb49cbc4151aa06b0dacecc7025ad2ed7d85f42`; Build 32 application delta is rooted at the source revision; Alembic is `20260823_0036` |
| App tests | `FiscalKitTests`: 410 passed / 41 suites / 0 failed; focused F3-F: 34 passed; iOS unknown-delete refresh UI: 1 passed |
| App builds | Signed macOS universal Release and iOS arm64 device Release built from the clean source revision |
| Git | Source revision pushed to `origin/main`; existing `v1.5.5` remains immutable; Build 32 uses `v1.5.5-build32` |
| macOS signing | Developer ID Application: ZheYuan Cai (HX73DFL88G); hardened runtime and secure timestamp enabled; no notarization |
| macOS install | `/Applications/Fiscal.app` replaced, strictly verified and launched as `1.5.5 (32)` |
| iOS delivery | Development-signed arm64 IPA prepared for operator installation; no TestFlight upload or installation |

### Build 32 fix and invariants

- Ordinary refresh captures an active direct-mutation owner before list loading and resolves the owner through a fresh GET instead of allowing a new list response to orphan its lock.
- A fresh 404 confirms deletion and unlocks; an existing proposal restores that proposal and its recovery surface; a failed fresh read retains the owner, lock and retry entry.
- All three paths issue exactly one DELETE. Refresh and recovery never replay the mutation.
- macOS and iOS use the same corrected model. The existing selection-isolation and D3 safety gates remain covered and passing.

### Verification and production deployment

- Focused F3-F passed 34/34; full `FiscalKitTests` passed 410/410 in 41 suites; the iOS user path for delete → unknown → ordinary refresh passed 1/1.
- Both signed source apps and their extracted delivery packages passed `codesign --verify --deep --strict`; source/extracted executable hashes match exactly.
- Both apps report `1.5.5 (32)` and target `https://fiscal.linotsai.top`. macOS is universal `x86_64 arm64`; iOS is `arm64` with provisioning profile `c2ca777b-b04b-484e-826e-eef28085a121`, valid through 2027-07-21.
- Production was re-anchored read-only at revision `3a584da74a41e0d0e05335f923bbb44021795918`, Alembic `20260816_0035`, active/ready, before apply.
- The committed Build 32 source passed production Ruff format/check, Pyright (0 errors/warnings), and the database-independent release suite (149 passed, 244 PostgreSQL-gated skipped).
- Deployment created and verified pre-migration backup `fiscal-20260823T143536Z.dump`, upgraded to `20260823_0036`, then created and verified current-head backup `fiscal-20260823T143538Z.dump`.
- At the original Build 32 deployment, `/opt/fiscal/current` resolved to `/opt/fiscal/releases/5bf795625673`; service, local readiness and public liveness passed, and an unauthenticated DELETE probe returned 401. The later Ningbo migration and current production revision are recorded below.

### Build 32 artifacts

Directory: `build/release-v1.5.5-32/artifacts/`

| Artifact | SHA-256 |
| --- | --- |
| `Fiscal-macOS-v1.5.5-build32.zip` | `e4b1cd4904ae53218f84b118bd078ef2ae47d97b8e0670b7e9aa306421c16d37` |
| `Fiscal-macOS-v1.5.5-build32-dSYM.zip` | `4211e9760b470eef9dec1f4955b9353383b4eb5d7f5e4b5101dfc050917bdc96` |
| `Fiscal-iOS-v1.5.5-build32-development.ipa` | `508124b519a6a525d0392dd9eed522d04fc068f34223d664d3a4af1768ffb881` |
| `Fiscal-iOS-v1.5.5-build32-dSYM.zip` | `adc17febf09c01900e8f9a8c56c1e925077b76d68ebcda318ed4b831d4d1cbbc` |
| `RELEASE.txt` | `ea9a152737524276c460e65ad890ba7d732b7e6d4a6df544b35c11babdd1f6c5` |

`SHA256SUMS` covers all five files and passed full verification. The macOS signed-source/extracted executable hash is `cc00009f04f64af644c5a7dd918a3dc16da6255ae4ba765ada953e601d9206bc`; the iOS hash is `2665ca9e4a7b2a4d99879afb7dc67af31e25ae9ae73d8e80a8363fd45dd8e0b7`.

### Installation and rollback

- Current macOS app: `/Applications/Fiscal.app`, `1.5.5 (32)`, running after strict signature and executable-identity checks.
- Immediate macOS fallback: `/Applications/Fiscal-v1.5.3-build29-backup-20260823-222919.app`, verified as `1.5.3 (29)`.
- Backend application rollback target is the prior release `3a584da74a41`; because Build 32 moved the schema to `0036`, do not use ordinary application-only rollback to the `0035` release. Follow the runbook and restore the verified pre-migration dump into a new database if a schema rollback is required; never run a blind Alembic downgrade.
- iOS installation remains the operator's action. No App Store/TestFlight upload and no Apple notarization were performed.

## 2026-08-30 Fiscal-only Hangzhou → Ningbo production migration

- The app version remained `1.5.5 (32)`. Production moved from Hangzhou `118.178.122.194` to Ningbo `114.66.2.205` without rebuilding either client.
- Ningbo runs revision `3eb49cbc4151aa06b0dacecc7025ad2ed7d85f42` from `/opt/fiscal/releases/3eb49cbc4151`, with PostgreSQL 16 and Alembic `20260823_0036`. The API and all four operational timers are active and enabled.
- Hangzhou was frozen at `2026-08-30T11:13:32Z`. Its final dump and rollback package were transferred into `/var/lib/fiscal/backups/hz-cutover-20260830T111332Z/`; the restored production contains 225 transactions, 247 postings and zero orphan postings, with all three privacy-safe financial fingerprints matching the frozen source.
- Verified Ningbo backups include `/var/lib/fiscal/backups/fiscal-20260830T112126Z.dump` and `/var/lib/fiscal/backups/fiscal-20260830T115115Z.dump`; the latter has SHA-256 `3015f0312f214433c1be4566e13a51faeb9aa10712ec913f9e1a495d355e0630`. Restore verification passed.
- NPM `2.15.1` is the only public 80/443 ingress and proxies `fiscal.linotsai.top` to `172.18.0.1:8010`. The migrated certificate fingerprint is `81:45:DD:B1:43:1C:4D:CE:D5:B2:1B:0D:1C:59:17:21:79:8D:EC:03:48:25:1D:9C:8A:3D:DE:AF:69:32:35:23`, valid through 2026-10-14. Public readiness is deliberately blocked with 403 while local readiness is 200.
- The authoritative Aliyun A record is enabled at `114.66.2.205` with a 10-minute TTL. AliDNS and Cloudflare DoH, an external Hangzhou probe, strict TLS, public liveness 200, protected-route 401 and authenticated reads all confirmed the Ningbo endpoint.
- The installed macOS app loaded Ningbo production through the unchanged public domain. A real iPhone launch produced authenticated 200 responses for auth, system status, reconciliation, monthly reporting and facts endpoints on Ningbo.
- All 50 Hangzhou `fiscal*` databases (one production and 49 historical drill shadows) were individually dumped and verified before retirement. The complete cold archive is `/var/lib/fiscal/backups/hz-retired-archive/fiscal-hz-retirement-20260830T115250Z.tar.gz`, 464,855,406 bytes, SHA-256 `d54b9d05a948874f76bbe1330686e5a02cbb465b665fc20fe5334e0930bfc086`.
- After archive verification, Hangzhou Fiscal services/timers, Nginx vhost, Fiscal certificate, databases/roles, OS identity and active paths were removed. Final audit found zero Fiscal unit references, zero Fiscal databases, no Fiscal OS user/group, zero active Fiscal paths and no `8010` listener; shared Nginx/PostgreSQL and non-Fiscal projects remained active.
- DNS-only rollback is forbidden. Any cross-host rollback must first stop Ningbo writes, create and verify a new current Ningbo dump, restore and validate the target, and only then change DNS.

Detailed acceptance evidence: `NB_MIGRATION_ACCEPTANCE_20260830.md`.

## Historical preparation: v1.5.5 (Build 31)

| Field | Prepared state |
| --- | --- |
| Scope | Permanently delete unposted AI input after confirmation; classify AI provider failures without exposing private input or engineering codes |
| Source revision | `a21e17c465b29ce3c1899526c504dcf221185f67` (`feat(ai): delete unposted proposals and explain failures`) |
| Backend | Source and migration `20260823_0036` prepared and fully tested; production service and database remain unchanged |
| App tests | `FiscalKitTests`: 407 passed / 41 suites / 0 failed; focused F3-F model: 31 passed; iOS F3-F UI: 11 passed / 0 failed |
| App builds | Final signed macOS universal Release and iOS arm64 device Release built from the clean source revision |
| Git | Source commit exists locally; release-record commit, immutable `v1.5.5` tag and push are completed as the final preparation step |
| macOS signing | Developer ID Application: ZheYuan Cai (HX73DFL88G); hardened runtime and secure timestamp enabled; no notarization |
| macOS install | Deliberately unchanged: `/Applications/Fiscal.app` remains v1.5.3 (29) |
| iOS delivery | Development-signed arm64 IPA prepared for operator installation; no TestFlight upload or installation |

## Completed fixes

- Pending, failed and ignored AI input that has never produced a transaction or cash-flow item can be deleted through a system confirmation dialog on both macOS and iOS.
- Executed, undone, processing and unknown future states remain protected. The service checks version, status and linked facts under a mutation lock; the database independently rejects direct deletion of protected proposals.
- Deleting an eligible proposal also removes its private source input and quality events. Direct modification or deletion of an individual quality event remains forbidden.
- A delete response with an uncertain outcome never triggers an automatic second DELETE. The client performs a fresh GET and only treats 404 as confirmed deletion.
- Provider failures now distinguish rate limiting, upstream failure, timeout, connection failure, configuration rejection and invalid response. Safe structured logs omit credentials, authorization headers, user text and upstream response bodies.
- iOS now dismisses the keyboard when AI input is submitted so recovery and validation controls remain reachable.

## Verification evidence

- Backend: Ruff format/check passed; Pyright reported 0 errors and 0 warnings; full disposable-PostgreSQL suite passed 393 tests.
- App: focused F3-F model suite passed 31 tests; full shared suite passed 407 tests / 41 suites; iOS F3-F Gallery UI passed all 11 tests, including deletion confirmation/cancellation, user-facing provider failure text, response-unknown recovery and AX5 long content.
- Final `FiscaliOS` generic-simulator Release, `FiscalmacOS` Release, macOS UI `build-for-testing`, signed device builds and `V15GallerySnapshotTool` Release all built successfully.
- macOS F3-F UI automation was attempted three times but the host timed out while enabling automation mode before any business test started. This is not recorded as a pass. The shared macOS UI compiled for testing, and 15 F3-F snapshots supplied light, dark, error and AX5 visual evidence.
- Signed macOS and iOS products passed strict deep signature verification before packaging and after extraction. Extracted executable hashes exactly match their signed source products.
- Both apps report `1.5.5 (31)`, target `https://fiscal.linotsai.top`, and `git diff --check` passed before the source commit.

## Artifacts

Directory: `build/release-v1.5.5-31/artifacts/`

| Artifact | SHA-256 |
| --- | --- |
| `Fiscal-macOS-v1.5.5-build31.zip` | `62a4a9f5c8042b348146293dc1a4cbe4a57b72bc3fb890a4cc2c82781d4fcdb5` |
| `Fiscal-macOS-v1.5.5-build31-dSYM.zip` | `3cca5cf8ea4de3078dcf465a2cd561d648e2f4c3c6470c46afab2b8c05d3ec3d` |
| `Fiscal-iOS-v1.5.5-build31-development.ipa` | `89e585ed6e5ad07626ba7c1c7527ce95bf75fdf8d60730d7d59d57f39cb04081` |
| `Fiscal-iOS-v1.5.5-build31-dSYM.zip` | `5634eeebaf9be39a8d71d2e0bf20bcd62929333bdce5cd19434ae6e1682c6a48` |
| `RELEASE.txt` | `2ca8153346d30fe98569434659be6f8869e7b89f1c98beecdc0be705a7f2e794` |

`SHA256SUMS` covers all five files and passed full verification. The macOS signed-source and extracted executable hash is `54746f33b32903f2779724430b2e1aced15a75da75286ae6ada3dfe8c1d6c9ee`; the corresponding iOS hash is `265576eb71e0a9495090ef5f419ef35e70ec5465cacfe14da33e0c1a8e6ab79c`.

## Deployment handoff and rollback boundary

- Backend deployment is intentionally not run. The prepared entry point is `sudo Backend/ops/production/scripts/deploy.sh --source /path/to/Fiscal`; it must be reviewed in dry-run mode before adding `--apply`.
- Before apply, record the live `/opt/fiscal/current` revision as the application rollback target. The deploy workflow creates and verifies a pre-migration backup before applying `20260823_0036`, then creates a second current-head backup.
- Application rollback may use `rollback.sh` only if the target release has the same Alembic head as the live database. Because v1.5.5 changes schema, a post-migration rollback to the previous application is expected to require deliberate restoration of the verified pre-migration dump into a new database rather than `alembic downgrade`.
- macOS replacement is intentionally not run. The prepared replacement source is the verified app inside `Fiscal-macOS-v1.5.5-build31.zip`; the currently installed v1.5.3 app remains the immediate local fallback until the operator authorizes the swap.

## Deliberately not performed

- No production Backend deployment, database migration, server restart, authenticated production smoke or production data access.
- No replacement or launch of `/Applications/Fiscal.app`.
- No iOS installation, App Store upload or TestFlight upload.
- No Apple notarization.
