# PakConnect readiness audit

Last audited: 2026-07-29

This is the requirement-level closeout surface for the current readiness
program. It does not replace the detailed codebase, runtime, debt, engineering
or device ledgers; it states what those sources prove and what they do not.

## Verdict

**Local code/build readiness: green. Public CI is protected-PR-gated; final FYP
demo and release readiness are not yet proven.**

The canonical worktree is mapped, statically clean, covered by a green
5,691-test desktop suite, and produces a debug Android APK. That is sufficient
to present the architecture and engineering hardening honestly in a portfolio,
provided the public-CI and hardware boundaries are disclosed. It is not
sufficient to claim a working off-grid BLE product: PR #73 must record green
required checks on its exact final head, while two-device radio behavior,
mobile SQLCipher bytes at rest, OS background behavior, release signing and
installation still require external evidence.

The exact verified runtime/build-input and device-test tree is committed as
`7944c9385a367746646229f5f33c410a39d57570` (`7944c93`) on
`codex/archive-delete-contract`. Public `main` is `df30c99`; the pushed branch
is ahead of and zero behind it and is published through normal PR #73. Changes
after the verified baseline are documentation, guidance, testing scripts, and
assistant metadata only. Protected `main` strictly requires `test`,
`Analyze GitHub Actions`, and `Analyze Java/Kotlin (Android)`.
The route-hardening baseline `53bb4fe`, its status descendant `ed4d416`, and
toolchain checkpoint `eccced7` are provenance only; `eccced7` is superseded by
`7944c93`. Former baselines `5a2cb8e` and `979e106`, plus candidate `0c8fa87`,
are older historical provenance.

## Objective evidence matrix

| Requested outcome | Authoritative evidence | Verdict |
|---|---|---|
| Establish authoritative repo/version | `docs/status/ENGINEERING_STATUS.md` records remote `AbubakarMahmood/pak_connect`, sole active worktree, PR branch `codex/archive-delete-contract`, runtime/device baseline `7944c93`, public head `df30c99`, Flutter 3.44.4 and Dart 3.12.2 | Proven |
| Preserve/reconcile the two source copies | Engineering status records the compressed checkpoint as recovery evidence and the canonical repo as the only active worktree | Proven |
| Inventory modules and ownership | `docs/architecture/CODEBASE_MAP.md` defines the accepted owner/layer boundary: all 437 libraries are included in layer counts and reachability evaluation, live behavior is routed through named owners/invariants, and the four non-runtime libraries have machine-readable owners and exit conditions | Proven at the accepted whole-library/owner boundary; member-level liveness is not implied |
| Map runtime interactions | `docs/architecture/RUNTIME_FLOWS.md` covers bootstrap, BLE bring-up, identities, direct send/receive, relay, queue sync, verified friend reveal, broadcast lists and persistence | Proven/documented for wired Dart paths; device behavior remains gated |
| Maintain work-thread inventory | `PLANS.md`, `docs/maintenance/DEBT_REGISTER.md` and `docs/status/ENGINEERING_STATUS.md` separate completed, accepted, investigated and device-gated work | Proven |
| Reconcile documentation | README, CONTRIBUTING, testing guides, threat/security docs and SRS distinguish current behavior, historical targets and device-only claims | Proven locally; PR #73 is the publication record |
| Detect/fix bugs and design issues | Engineering status promotion table records correlated queue sync, exact route/MTU, strict-TDM generations, ACK ownership, authenticated final-relay persistence, reconnect/resume, typed failure, bounded fragmentation, verified reveal, archive/unread and broadcast-list fixes | Proven by focused and full-suite evidence |
| Perform targeted refactors/cleanup | Production change-log replay removed from composition; 44 unjustified libraries, six island-only test clusters and orphan Node/MCP manifests removed; no umbrella rewrite introduced | Proven |
| Strengthen verification | Analyzer clean; reachability enforcement has zero unreviewed candidates; `git diff --check` and runner syntax pass; full suite 5,691/5,691 with coverage; debug APK builds | Proven locally |
| Reconcile public CI | Historical run `29215130687` failed two suites through a shared test-database collision; commit `569ff9a` isolates them. Protected `main` now requires Flutter coverage plus Android and Actions CodeQL, with PR #73 as the exact-head record | Fix proven locally; merge remains conditional on green required PR checks |
| Track device/deferred work | `docs/testing/DEVICE_VALIDATION_STATUS.md` and the debt register name every hardware/environment gate and its exit condition | Proven as tracking; execution pending |
| Evaluate ideas on merit | Strict TDM was hardened and retained; change-log replay and relay privacy claims were disabled/bounded; true groups and multi-link payloads were not fabricated; dead code/tooling decisions use reachability and dependency evidence | Proven by recorded decisions |
| Demonstrably ready for final FYP demo/release | Requires the physical-device and signed-release exit gate below | Not yet proven |

## Current verification evidence

- Baseline delta after the `53bb4fe`/`ed4d416` pair: `db529df`
  corrects Android notification claims to system-tray rendering while the app
  runs; `eccced7` locks CI/package authority to Flutter 3.44.4 and preserves
  Android compatibility flags; `5142358` reports archive compression honestly;
  `d584f44` replaces public Flutter template branding; and `7944c93` clarifies
  dormant BLE contract seams. The exact final runtime/build-input tree is
  `7944c93`.

- `flutter analyze --no-pub`: zero issues.
- Local Markdown link audit: zero broken relative targets and zero absolute
  user-profile links in live repository docs.
- `pwsh -NoProfile -File tools/dart_reachability_audit.ps1 -FailOnUnreviewed`:
  437 libraries, 433 runtime-reachable, four reviewed test-only candidates,
  zero unreviewed candidates.
- Strict BLE gate: 108 tests passed. Crypto policy gate: all 14 cases passed.
- DI audit: zero direct `GetIt` calls and 16 reviewed `.instance` references.
  Runtime hygiene audit: zero `print()` calls and 21 reviewed timers.
- Focused promotion suites: 273 change-log/reveal/runtime tests; 52
  broadcast-list tests; 38 fragment/model regressions; 36 app widget/smoke
  regressions, all green.
- Full `flutter test --coverage`: 5,691 passed, zero failed; reporter duration
  5m37s and measured wall time 353,083 ms. Complete terminal output is saved in
  the 9,268,167-byte
  `flutter_test_latest.log` (SHA-256
  `78798AD4575FB77E3B99F50C5D30B4715CE44CAA9BDC5245982CAF5F3892C905`).
- Coverage output is the 426,546-byte `coverage/lcov.info` (SHA-256
  `57F95535FC93711B39344343A1D8F2DE644B9697EA23F45204D1529CE84BF794`).
- Debug APK:
  `build/app/outputs/flutter-apk/app-debug.apk`, 205,113,616 bytes, SHA-256
  `84C9B0F5E32D34C90C06D2F9CE7787E23AF60CF79692395B75C2B5DC0BF46059`.
- Latest public-main Flutter workflow `29215130687`: 5,537 passed and two
  failed with SQLite `database is locked`; both failures used the production
  test filename concurrently. Commit `569ff9a` preserves suite-specific names;
  protected PR #73 is the exact-head Flutter and CodeQL publication record.
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
9. Hardware evidence must cite runtime/device baseline `7944c93` plus the APK
   hash. `53bb4fe`, `ed4d416`, `eccced7` and older baselines are historical
   evidence only.
10. Auto-archive of inactive chats is implemented only as the preference-led,
    in-process `AutoArchiveScheduler`. Advanced archive policy selection,
    maintenance task effects, compression persistence and maintenance-history
    storage remain placeholders/debt and are not implied by that scheduler.
11. A dependency refresh is pending: the 2026-07-14 Flutter 3.44.4 snapshot
    reports 22 outdated direct-dependency rows, 45 dependencies locked below
    an upgradable version and 13 constraints below a resolvable version. The
    exact-release dependency-license/notices and crypto-distribution audit is
    also open.
12. Populated v10 -> v11 -> v12 migration, mixed app versions, accessibility,
    numeric performance/battery targets and distribution licensing remain
    actionable test or release gates in the device ledger. The two-phone
    checklist deliberately installs one identical APK hash and cannot close a
    mixed-version or non-device legal gate.

## Exit gate and recommended order

Do not expand the architecture before the current hardware facts exist. The
recommended next sequence is:

1. Merge PR #73 only after the exact final head passes Flutter coverage plus
   Android and Actions CodeQL; then verify the resulting protected `main`.
2. Build/install runtime/device baseline `7944c93` on two Android phones, execute
   `docs/testing/TWO_ANDROID_DEVICE_EXECUTION_CHECKLIST.md`, and update every
   observed row in `docs/testing/DEVICE_VALIDATION_STATUS.md`, saving redacted
   logs by device/build/commit.
3. Reproduce and fix only failures observed by that matrix, rerunning focused
   tests plus the full suite after each production change.
4. Prove SQLCipher at rest on Android using the documented credential and
   direct-file-open procedure.
5. Supply and verify release signing, build the release APK, install it on both
   devices and rerun the critical XX/KK/direct/offline/fragment paths.
6. If the public mesh-relay claim is retained, add a third Android phone for
   multi-link inventory/routing and controlled `A -> B -> C` relay evidence.
7. Decide native background work and per-link multi-payload architecture from
   measured FYP requirements and device traces, not from feature pressure.

Final demo/release readiness becomes green only when those device rows pass or
an explicitly de-scoped claim is removed from the FYP/portfolio narrative.
