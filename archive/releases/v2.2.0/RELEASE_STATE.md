# Fiscal v2.2.0 (40) release state

2026-09-06, Asia/Shanghai. **RELEASE IN PROGRESS** — user explicitly authorized the established full release workflow.

- Client baseline: v2.1.0 (39), source 353c381ff6a2540a048e8c3d3a7d12b57e24e9ad. Installed executable matches the prior release manifest.
- Candidate: complete SwiftUI financial-workspace redesign and all review fixes, 2.2.0 / 40, iOS/macOS 26.0+. Review's 51 source hashes and test evidence rechecked; 408 unit tests and 43 cumulative distinct UI passes are reused, not rerun during release.
- Backend cumulative diff against last recorded live 64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4 is empty. Fresh authenticated API and SSH checks confirm the same live revision/schema, active service and four timers, healthy readiness, valid 15-hour-old backup plus successful restore verification; backup SHA-256 passed. No backend deploy, migration or release-only backup is required.
- Preserve six operator scheme edits byte-for-byte, exclude from commits. Build from exported committed App source with canonical schemes. Reuse the existing Fiscal DerivedData/ModuleCache, serial two-job builds, no new simulator/runtime.
- Next: finish production preflight, commit/push main and immutable v2.2.0 tag, build/sign/verify delivery archives, back up and replace/launch the local Mac client, copy verified iOS IPA to Downloads, archive final evidence and push delivery records.
- Only final physical iOS installation is handed to the user. No release or installation completion is claimed yet.
