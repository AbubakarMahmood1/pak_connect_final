# PakConnect readiness audit

Last audited: 2026-07-11

This is the requirement-level closeout surface for the current readiness
program. It does not replace the detailed codebase, runtime, debt, engineering
or device ledgers; it states what those sources prove and what they do not.

## Verdict

**Local code/build readiness: green. Final FYP demo/release readiness:
not yet proven.**

The canonical worktree is mapped, statically clean, covered by a green
5,534-test desktop suite, and produces a debug Android APK. That is sufficient
to present the architecture and engineering hardening honestly in a portfolio.
It is not sufficient to claim a working off-grid BLE product: two-device
radio behavior, mobile SQLCipher bytes at rest, OS background behavior,
release signing and installation still require external evidence.

The exact verified code/test/tooling tree is committed as `a5c2b08` on
`codex/reconcile-pakconnect`; it has not been pushed.

## Objective evidence matrix

| Requested outcome | Authoritative evidence | Verdict |
|---|---|---|
| Establish authoritative repo/version | `docs/status/ENGINEERING_STATUS.md` records remote `AbubakarMahmood/pak_connect`, branch `codex/reconcile-pakconnect`, Flutter 3.41.5 and Dart 3.11.3 | Proven |
| Preserve/reconcile the two source copies | Engineering status records the compressed checkpoint as recovery evidence and the canonical repo as the only active worktree | Proven |
| Inventory modules and ownership | `docs/architecture/CODEBASE_MAP.md` maps 437 libraries, layers, runtime owners, high-scrutiny surfaces and invariants | Proven at whole-library/owner level |
| Map runtime interactions | `docs/architecture/RUNTIME_FLOWS.md` covers bootstrap, BLE bring-up, identities, direct send/receive, relay, queue sync, verified friend reveal, broadcast lists and persistence | Proven/documented for wired Dart paths; device behavior remains gated |
| Maintain work-thread inventory | `PLANS.md`, `docs/maintenance/DEBT_REGISTER.md` and `docs/status/ENGINEERING_STATUS.md` separate completed, accepted, investigated and device-gated work | Proven |
| Reconcile documentation | README, CONTRIBUTING, testing guides, threat/security docs and SRS now distinguish current behavior, historical targets and device-only claims | Proven for the reviewed surfaces |
| Detect/fix bugs and design issues | Engineering status promotion table records correlated queue sync, exact route/MTU, strict-TDM generations, ACK ownership, reconnect/resume, typed failure, bounded fragmentation, verified reveal, archive/unread and broadcast-list fixes | Proven by focused and full-suite evidence |
| Perform targeted refactors/cleanup | Production change-log replay removed from composition; 44 unjustified libraries, six island-only test clusters and orphan Node/MCP manifests removed; no umbrella rewrite introduced | Proven |
| Strengthen verification | Analyzer clean; reachability enforcement has zero unreviewed candidates; `git diff --check` and runner syntax pass; full suite 5,534/5,534; debug APK builds | Proven locally |
| Track device/deferred work | `docs/testing/DEVICE_VALIDATION_STATUS.md` and the debt register name every hardware/environment gate and its exit condition | Proven as tracking; execution pending |
| Evaluate ideas on merit | Strict TDM was hardened and retained; change-log replay and relay privacy claims were disabled/bounded; true groups and multi-link payloads were not fabricated; dead code/tooling decisions use reachability and dependency evidence | Proven by recorded decisions |
| Demonstrably ready for final FYP demo/release | Requires the physical-device and signed-release exit gate below | Not yet proven |

## Current verification evidence

- `flutter analyze --no-pub`: zero issues.
- Local Markdown link audit: zero broken relative targets and zero absolute
  user-profile links in live repository docs.
- `pwsh -NoProfile -File tools/dart_reachability_audit.ps1 -FailOnUnreviewed`:
  437 libraries, 433 runtime-reachable, four reviewed test-only candidates,
  zero unreviewed candidates.
- Focused promotion suites: 273 change-log/reveal/runtime tests; 52
  broadcast-list tests; 38 fragment/model regressions; 36 app widget/smoke
  regressions, all green.
- Full `flutter test --no-pub`: 5,534 passed, zero failed, 3m13s. Complete
  terminal output is saved in the 9,064,299-byte
  `flutter_test_latest.log` (SHA-256
  `01D2A10A477FEA1174C2D62F79EA4BBFCFE0466057F9E8666E1DC5CF5406F339`).
- Debug APK:
  `build/app/outputs/flutter-apk/app-debug.apk`, 203,988,860 bytes, SHA-256
  `3B541A9C734977BF43E2621BFE300EB7CB316DFA391430722E6375DD6CF1F040`.

Desktop SQLite fallback notices prove schema/migration behavior only. They are
not SQLCipher-at-rest evidence.

## Residual risks and accepted boundaries

1. Two Android devices have not exercised discovery in both roles, collision
   handling, Noise XX/KK, bidirectional direct delivery, offline reconnect,
   fragmentation, relay or rapid same-address reconnect.
2. Mobile SQLCipher file unreadability without the secure-storage credential
   is not proven.
3. Native background execution while the OS suspends or kills the process is
   not implemented/proven; only the Dart resume flush is covered.
4. Release signing and installable signed APK evidence is absent.
5. Multi-link direct payloads intentionally defer until one record binds BLE
   address/generation, verified handshake identity, Noise readiness and ACK
   ownership. Control-frame targeting does not remove this risk.
6. Broadcast Lists are sender-local multi-unicast. They do not provide shared
   membership, transcript, replies, admin rules or a group key.
7. Change-log peer replay and relay privacy/PoW primitives remain dormant and
   must not appear as shipped guarantees.
8. The verified baseline is committed but intentionally not pushed. Hardware
   evidence must cite `a5c2b08` (or a documentation-only descendant) plus the
   APK hash.

## Exit gate and recommended order

Do not expand the architecture before the current hardware facts exist. The
recommended next sequence is:

1. Build/install code baseline `a5c2b08` on two Android phones, execute
   `docs/testing/TWO_ANDROID_DEVICE_EXECUTION_CHECKLIST.md`, and update every
   observed row in `docs/testing/DEVICE_VALIDATION_STATUS.md`, saving redacted
   logs by device/build/commit.
2. Reproduce and fix only failures observed by that matrix, rerunning focused
   tests plus the full suite after each production change.
3. Prove SQLCipher at rest on Android using the documented credential and
   direct-file-open procedure.
4. Supply and verify release signing, build the release APK, install it on both
   devices and rerun the critical XX/KK/direct/offline/fragment paths.
5. Decide native background work and per-link multi-payload architecture from
   measured FYP requirements and device traces, not from feature pressure.

Final demo/release readiness becomes green only when those device rows pass or
an explicitly de-scoped claim is removed from the FYP/portfolio narrative.
