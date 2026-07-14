# PakConnect readiness audit

Last audited: 2026-07-14

This is the requirement-level closeout surface for the current readiness
program. It does not replace the detailed codebase, runtime, debt, engineering
or device ledgers; it states what those sources prove and what they do not.

## Verdict

**Local code/build readiness: green. Public-CI, final FYP demo and release
readiness: not yet proven.**

The canonical worktree is mapped, statically clean, covered by a green
5,691-test desktop suite, and produces a debug Android APK. That is sufficient
to present the architecture and engineering hardening honestly in a portfolio,
provided the public-CI limitation is disclosed. It is not sufficient to claim
a working off-grid BLE product: exact-head GitHub CI, two-device radio
behavior, mobile SQLCipher bytes at rest, OS background behavior, release
signing and installation still require external evidence.

The exact verified runtime/build-input and device-test tree is committed as
`d5f6d7edded25dc6e935bd366e7a7e8be08b7901` (`d5f6d7e`) on
`codex/archive-delete-contract`. Public `main` remains at `1d484eb`; the
current local branch is 18 commits ahead after this documentation closeout and
has not been pushed. No branch protection/ruleset, pushed branch, PR or
exact-head GitHub verification exists. Seventeen commits are the local
durability/route/toolchain hardening chain; the eighteenth is this docs-only
descendant.
The previous baseline `9f0a055` and its documentation-only descendant
`18be950` are provenance only. Former baselines `9cccd01` and `a5c2b08`, plus
candidate `fcb3013`, are older historical provenance.

## Objective evidence matrix

| Requested outcome | Authoritative evidence | Verdict |
|---|---|---|
| Establish authoritative repo/version | `docs/status/ENGINEERING_STATUS.md` records remote `AbubakarMahmood/pak_connect`, sole active worktree, local branch `codex/archive-delete-contract`, runtime/device baseline `d5f6d7e`, public head `1d484eb`, Flutter 3.44.4 and Dart 3.12.2 | Proven |
| Preserve/reconcile the two source copies | Engineering status records the compressed checkpoint as recovery evidence and the canonical repo as the only active worktree | Proven |
| Inventory modules and ownership | `docs/architecture/CODEBASE_MAP.md` maps 437 libraries, layers, runtime owners, high-scrutiny surfaces and invariants | Proven at whole-library/owner level |
| Map runtime interactions | `docs/architecture/RUNTIME_FLOWS.md` covers bootstrap, BLE bring-up, identities, direct send/receive, relay, queue sync, verified friend reveal, broadcast lists and persistence | Proven/documented for wired Dart paths; device behavior remains gated |
| Maintain work-thread inventory | `PLANS.md`, `docs/maintenance/DEBT_REGISTER.md` and `docs/status/ENGINEERING_STATUS.md` separate completed, accepted, investigated and device-gated work | Proven |
| Reconcile documentation | README, CONTRIBUTING, testing guides, threat/security docs and SRS distinguish current behavior, historical targets and device-only claims | Proven locally for the reviewed surfaces; publication pending |
| Detect/fix bugs and design issues | Engineering status promotion table records correlated queue sync, exact route/MTU, strict-TDM generations, ACK ownership, authenticated final-relay persistence, reconnect/resume, typed failure, bounded fragmentation, verified reveal, archive/unread and broadcast-list fixes | Proven by focused and full-suite evidence |
| Perform targeted refactors/cleanup | Production change-log replay removed from composition; 44 unjustified libraries, six island-only test clusters and orphan Node/MCP manifests removed; no umbrella rewrite introduced | Proven |
| Strengthen verification | Analyzer clean; reachability enforcement has zero unreviewed candidates; `git diff --check` and runner syntax pass; full suite 5,691/5,691 with coverage; debug APK builds | Proven locally |
| Reconcile public CI | Latest public-main run `29215130687` failed two suites through a shared test-database collision; local commit `4fd8aec` isolates them, but `main` has no protection and no current branch/PR run exists | Fix proven by local full-suite evidence; push, PR and exact-head GitHub run pending |
| Track device/deferred work | `docs/testing/DEVICE_VALIDATION_STATUS.md` and the debt register name every hardware/environment gate and its exit condition | Proven as tracking; execution pending |
| Evaluate ideas on merit | Strict TDM was hardened and retained; change-log replay and relay privacy claims were disabled/bounded; true groups and multi-link payloads were not fabricated; dead code/tooling decisions use reachability and dependency evidence | Proven by recorded decisions |
| Demonstrably ready for final FYP demo/release | Requires the physical-device and signed-release exit gate below | Not yet proven |

## Current verification evidence

- Baseline delta after the previous `9f0a055`/`18be950` pair: `63d426a`
  corrects Android notification claims to system-tray rendering while the app
  runs; `d5f6d7e` locks CI/package authority to Flutter 3.44.4, enforces the
  lockfile, and preserves the Android built-in-Kotlin/new-DSL compatibility
  flags pending a separate migration.

- `flutter analyze --no-pub`: zero issues.
- Local Markdown link audit: zero broken relative targets and zero absolute
  user-profile links in live repository docs.
- `pwsh -NoProfile -File tools/dart_reachability_audit.ps1 -FailOnUnreviewed`:
  437 libraries, 433 runtime-reachable, four reviewed test-only candidates,
  zero unreviewed candidates.
- Focused promotion suites: 273 change-log/reveal/runtime tests; 52
  broadcast-list tests; 38 fragment/model regressions; 36 app widget/smoke
  regressions, all green.
- Full `flutter test --coverage`: 5,691 passed, zero failed; reporter duration
  6m30s and measured wall time 401,348 ms. Complete terminal output is saved in
  the 9,172,538-byte
  `flutter_test_latest.log` (SHA-256
  `387A72AFBBEDD7C006E4FF1A9327FAA6F7C7EE56F7441139C6DFB734D95180AC`).
- Coverage output is the 426,841-byte `coverage/lcov.info` (SHA-256
  `B8E8B422E6DB62D44CD5E3A6D26C3EC03A9EADC4231755B9A184A62BBE6B6CC8`).
- Debug APK:
  `build/app/outputs/flutter-apk/app-debug.apk`, 205,109,632 bytes, SHA-256
  `9F30BB6A42AB8B8392B13A62282BA10F8ADD1FF3F2C419FA04B0DF4C8CEC110A`.
- Latest public-main Flutter workflow `29215130687`: 5,537 passed and two
  failed with SQLite `database is locked`; both failures used the production
  test filename concurrently. Local commit `4fd8aec` preserves suite-specific
  names, but a fresh GitHub run on the current exact head does not exist yet.
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
9. Hardware evidence must cite runtime/device baseline `d5f6d7e` plus the APK
   hash. `9f0a055`/`18be950` and older baselines are historical evidence only.

## Exit gate and recommended order

Do not expand the architecture before the current hardware facts exist. The
recommended next sequence is:

1. Protect `main`, publish the current local chain through a normal non-force
   branch/PR, and require the exact PR head to pass Flutter coverage and
   CodeQL; do not treat the local green run as public-CI evidence.
2. Build/install runtime/device baseline `d5f6d7e` on two Android phones, execute
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
