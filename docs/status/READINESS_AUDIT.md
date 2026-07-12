# PakConnect readiness audit

Last audited: 2026-07-13

This is the requirement-level closeout surface for the current readiness
program. It does not replace the detailed codebase, runtime, debt, engineering
or device ledgers; it states what those sources prove and what they do not.

## Verdict

**Local code/build readiness: green. Final FYP demo/release readiness:
not yet proven.**

The canonical worktree is mapped, statically clean, covered by a green
5,539-test desktop suite, and produces a debug Android APK. That is sufficient
to present the architecture and engineering hardening honestly in a portfolio.
It is not sufficient to claim a working off-grid BLE product: two-device
radio behavior, mobile SQLCipher bytes at rest, OS background behavior,
release signing and installation still require external evidence.

The exact verified code/build-input tree is committed as
`fcb3013215484d2e5b3c3b75f655d81c28209171` (`fcb3013`) on
`codex/reconcile-pakconnect`. A documentation-only descendant is acceptable
only when its build-input diff from that commit is empty. The former
`a5c2b08` baseline remains historical provenance.

## Objective evidence matrix

| Requested outcome | Authoritative evidence | Verdict |
|---|---|---|
| Establish authoritative repo/version | `docs/status/ENGINEERING_STATUS.md` records remote `AbubakarMahmood/pak_connect`, branch `codex/reconcile-pakconnect`, Flutter 3.41.5 and Dart 3.11.3 | Proven |
| Preserve/reconcile the two source copies | Engineering status records the compressed checkpoint as recovery evidence and the canonical repo as the only active worktree | Proven |
| Inventory modules and ownership | `docs/architecture/CODEBASE_MAP.md` maps 437 libraries, layers, runtime owners, high-scrutiny surfaces and invariants | Proven at whole-library/owner level |
| Map runtime interactions | `docs/architecture/RUNTIME_FLOWS.md` covers bootstrap, BLE bring-up, identities, direct send/receive, relay, queue sync, verified friend reveal, broadcast lists and persistence | Proven/documented for wired Dart paths; device behavior remains gated |
| Maintain work-thread inventory | `PLANS.md`, `docs/maintenance/DEBT_REGISTER.md` and `docs/status/ENGINEERING_STATUS.md` separate completed, accepted, investigated and device-gated work | Proven |
| Reconcile documentation | README, CONTRIBUTING, testing guides, threat/security docs and SRS now distinguish current behavior, historical targets and device-only claims | Proven for the reviewed surfaces |
| Detect/fix bugs and design issues | Engineering status promotion table records correlated queue sync, exact route/MTU, strict-TDM generations, ACK ownership, authenticated final-relay persistence, reconnect/resume, typed failure, bounded fragmentation, verified reveal, archive/unread and broadcast-list fixes | Proven by focused and full-suite evidence |
| Perform targeted refactors/cleanup | Production change-log replay removed from composition; 44 unjustified libraries, six island-only test clusters and orphan Node/MCP manifests removed; no umbrella rewrite introduced | Proven |
| Strengthen verification | Analyzer clean; reachability enforcement has zero unreviewed candidates; `git diff --check` and runner syntax pass; full suite 5,539/5,539; debug APK builds | Proven locally |
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
- Full `flutter test --no-pub`: 5,539 passed, zero failed, 4m56s. Complete
  terminal output is saved in the 9,200,096-byte
  `flutter_test_latest.log` (SHA-256
  `80BCAA4C731DA95071547487DEFAFA612945CF338F55DCF491567D4A0395C2B4`).
- Debug APK:
  `build/app/outputs/flutter-apk/app-debug.apk`, 203,988,403 bytes, SHA-256
  `40DBD095BF796A71B8B66DB6194724E2699325D3BF457093758276903EAF3C92`.
- Final relay regression evidence proves that the signed encrypted v2 inner
  `ProtocolMessage` is decoded, authenticated/decrypted and persisted before
  the routed ACK. Processing failure emits no ACK and does not mark the message
  seen; a duplicate completed delivery resends the ACK without redelivery.

Desktop SQLite fallback notices prove schema/migration behavior only. They are
not SQLCipher-at-rest evidence.

## Residual risks and accepted boundaries

1. Two Android devices have not exercised the executable A/B rows: discovery
   in both roles, collision handling, Noise XX/KK, bidirectional direct
   delivery, offline reconnect, fragmentation, foreground/background/resume or
   rapid same-address reconnect.
2. Multi-link inventory/routing and `A -> B -> C` relay require a third Android
   phone. Desktop regressions do not substitute for that three-phone evidence.
3. Mobile SQLCipher file unreadability without the secure-storage credential
   is not proven. Controlled secure-storage fault injection is `BLOCKED`
   because the current baseline has no reviewed safe injection hook.
4. Native background execution while the OS suspends, kills or dozes the process is
   not implemented/proven; only the Dart resume flush is covered.
5. Release signing and installable signed APK evidence is absent.
6. Multi-link direct payloads intentionally defer until one record binds BLE
   address/generation, verified handshake identity, Noise readiness and ACK
   ownership. Control-frame targeting does not remove this risk.
7. Broadcast Lists are sender-local multi-unicast. They do not provide shared
   membership, transcript, replies, admin rules or a group key.
8. Change-log peer replay and relay privacy/PoW primitives remain dormant and
   must not appear as shipped guarantees.
9. Hardware evidence must cite `fcb3013` (or a documentation-only descendant
   with an empty build-input diff) plus the APK hash. `a5c2b08` is historical
   evidence only.

## Exit gate and recommended order

Do not expand the architecture before the current hardware facts exist. The
recommended next sequence is:

1. Build/install code baseline `fcb3013` on two Android phones, execute
   `docs/testing/TWO_ANDROID_DEVICE_EXECUTION_CHECKLIST.md`, and update every
   observed row in `docs/testing/DEVICE_VALIDATION_STATUS.md`, saving redacted
   logs by device/build/commit.
2. Reproduce and fix only failures observed by that matrix, rerunning focused
   tests plus the full suite after each production change.
3. Prove SQLCipher at rest on Android using the documented credential and
   direct-file-open procedure.
4. Supply and verify release signing, build the release APK, install it on both
   devices and rerun the critical XX/KK/direct/offline/fragment paths.
5. If the public mesh-relay claim is retained, add a third Android phone for
   multi-link inventory/routing and controlled `A -> B -> C` relay evidence.
6. Decide native background work and per-link multi-payload architecture from
   measured FYP requirements and device traces, not from feature pressure.

Final demo/release readiness becomes green only when those device rows pass or
an explicitly de-scoped claim is removed from the FYP/portfolio narrative.
