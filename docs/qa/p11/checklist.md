# Fiscal P11 QA Checklist

Date: 2026-07-16

## Device keys and API security

- [x] Production rejects legacy/static tokens and missing/short pepper.
- [x] Raw device keys appear once and never enter database, logs, argv, backups or Git in automated gates.
- [x] Pending activation and two-phase rotation survive ambiguous responses without lockout.
- [x] Operator/device authorization, stale-version conflicts and last-operator protection pass PostgreSQL tests.
- [x] Invalid, revoked, expired, malformed and oversized keys share one non-disclosing response.
- [x] Authenticated, write, AI and failed-auth rate limits return stable 429/Retry-After behavior.

## HZ production infrastructure

- [ ] Dedicated Unix user, database/roles, release directories and root-owned environment file exist.
- [ ] API and PostgreSQL listen only on loopback; UFW exposes only 22/80/443.
- [ ] Hardened systemd service, Nginx TLS/reverse proxy and log rotation validate cleanly.
- [ ] Existing HZ sites/services remain unchanged and healthy.
- [ ] DNS and certificate for `fiscal.linotsai.top` are active before public cutover.

## Backup, restore and operations

- [ ] Daily custom-format backup, checksum, archive validation and 14-day local retention pass.
- [ ] Encrypted off-host copy or confirmed cloud snapshot policy is verified.
- [ ] Isolated restore drill reaches Alembic head and validates canonical data invariants.
- [ ] Pre-migration backup, forward migration, release rollback and incompatible-schema recovery are documented and exercised proportionally.
- [ ] Health, backup age, restore status and 75%/85% disk thresholds reach a real notification channel.

## Apple clients

- [ ] iOS/macOS show real VPS, sync, current-device, backup and security facts.
- [x] Safe rotation writes the successor to Keychain before activation and confirms the new key before removing the old one.
- [x] “Remove this device key” uses accurate semantics; no logout or fake E2EE control exists.
- [x] Release builds target `https://fiscal.linotsai.top` without embedded production secrets.

## Final

- [x] Full backend, migration, iOS 26 and macOS 26 local gates pass.
- [ ] Service/API and PostgreSQL restarts preserve data and authentication.
- [ ] User accepts P11 production/security behavior before P12 begins.
