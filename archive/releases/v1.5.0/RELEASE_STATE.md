# Fiscal v1.5.0 source state

This is a pre-package source manifest. It is not a release announcement and
does not claim that signed or deployable artifacts exist.

## v1.5.0 (Build 24)

| Field | Current state |
| --- | --- |
| Source version | `1.5.0 (24)` |
| Apple composition | Formal iOS and macOS roots use V15 production services; Gallery and RootSmoke remain isolated QA targets |
| Legacy visual layer | Removed from the formal source graph |
| Backend schema head | `20260816_0035` in source |
| Previous released rollback | `v1.4.0` at `ef2cc382c6ad` |
| Release package | **Not generated** |
| Signing / notarization | **Not performed** |
| Tag / push | **Not performed** |
| Production backup / migration / deploy | **Not performed** |

## Deliberate stop point

The 2026-08-22 user direction was to finish the final code, organize the
workspace into a clean publishable source revision, bump the version, and stop
before package generation. Existing QA history is retained, but the final
source-only offline/error closeout was not followed by another long validation
cycle.

The next authorized release turn starts with package generation from the clean
Git revision. It must not silently modify source, sign, notarize, tag, push, or
deploy without the corresponding user authorization.
