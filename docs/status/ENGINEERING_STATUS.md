# PakConnect engineering status

Last updated: 2026-07-29

## Current verdict

The canonical source is reconciled, statically clean, green across the full
desktop suite, and produces an Android debug APK. The verified local suite
passes 5,691 tests after the deliberate removal of isolated dead
implementations and the addition of focused durability, route-ownership and
archive regressions. Publication is governed by normal PR #73 and protected
`main`; every final PR head must pass Flutter coverage plus Android and Actions
CodeQL before merge. Real BLE, SQLCipher-at-rest, native background behavior,
release signing and installation remain separate device/environment gates.

## Authority and preservation

- Canonical remote: `AbubakarMahmood/pak_connect`.
- The compressed working copy was checkpointed and archived before retirement;
  the verified bundle, not a second checkout, is recovery authority.
- PR #71 merged the reconciliation through normal merge commit `f99ed90`.
  PR #72 later advanced public `main` to `df30c99`.
- The only active worktree is on local branch
  `codex/archive-delete-contract`, ahead of and zero behind `origin/main`. The
  branch name is historical residue; it contains the subsequent durability,
  exact-route, archive-truth and metadata hardening chain. It is pushed as
  normal PR #73.
- Verified runtime/build-input and device-test baseline:
  `7944c9385a367746646229f5f33c410a39d57570` (`7944c93`) on
  `codex/archive-delete-contract`.
- Route-hardening baseline `53bb4fe`, status descendant `ed4d416`
  and toolchain checkpoint `eccced7` are historical provenance only;
  `eccced7` was superseded by `7944c93` and is not authority for a new device
  run.
- The former baselines `5a2cb8e` and `979e106` remain historical provenance,
  not baselines for a new device run.
- Candidate `0c8fa87` is also historical: Flutter 3.44 analysis required an
  equivalent null-aware syntax cleanup, which is included in `5a2cb8e`.
- The public mainline contains the earlier reconciled runtime and guidance,
  but not the current local durability/route/archive hardening chain or its
  non-runtime/build-input closeout descendants.
- Public `main` is protected with strict required contexts `test`,
  `Analyze GitHub Actions`, and `Analyze Java/Kotlin (Android)`. PR #73 is the
  immutable publication/check record for this chain.
- The former compressed checkout is not an authorized worktree and must not be
  recreated as a parallel working copy.

## Verification ledger

| Check | Evidence | Status |
|---|---|---|
| Flutter/Dart toolchain | Flutter 3.44.4 stable, Dart 3.12.2 | Green |
| Static analysis before current patch | `flutter analyze --no-pub` | Green |
| Pre-patch full desktop suite | 5,748 tests, 0 failures, about 4m42s | Green baseline |
| Current static analysis | `flutter analyze --no-pub`, clean on 2026-07-29 with Flutter 3.44.4 | Green |
| Dart reachability enforcement | 437 libraries; 433 runtime, 4 reviewed test-only, 0 unreviewed | Green |
| Strict BLE gate | 108 tests | Green |
| Crypto policy gate | 14 policy cases | Green |
| DI audit | 0 direct `GetIt` calls; 16 reviewed `.instance` references | Green |
| Runtime hygiene audit | 0 runtime `print()` calls; 21 reviewed timers | Green |
| Facade/reconnect regression | 121 focused tests | Green |
| Queue correlation, route containment and shared ACK | 169 focused tests | Green |
| Mark-unread service/HomeScreen behavior | 65 focused tests | Green |
| Queue-sync focused suite | 88 tests | Green |
| BLE promotion suite | 153 tests | Green |
| TDM/lifecycle/facade/queue recheck | 149 tests | Green |
| Fragment/reassembly suite | 63 tests | Green |
| Fragment production-call-site suite | Included in the prior promotion batch | Green focused evidence |
| Change-log/friend-reveal promotion suite | 273 tests | Green |
| Broadcast-list service/provider/UI suite | 52 tests | Green |
| Full-run failure regressions | 38 model/fragment tests + 36 app widget/smoke tests | Green |
| Current full desktop suite | 5,691 tests, 0 failures; reporter 5m37s, measured 353,083 ms; 9,268,167-byte `flutter_test_latest.log`, SHA-256 `78798AD4575FB77E3B99F50C5D30B4715CE44CAA9BDC5245982CAF5F3892C905`; 426,546-byte `coverage/lcov.info`, SHA-256 `57F95535FC93711B39344343A1D8F2DE644B9697EA23F45204D1529CE84BF794` | Green locally |
| Android debug APK | 205,113,616 bytes; SHA-256 `84C9B0F5E32D34C90C06D2F9CE7787E23AF60CF79692395B75C2B5DC0BF46059` | Green local build |
| Historical public-main Flutter workflow | Run `29215130687`: 5,537 passed, 2 failed because `database_helper_set_test_name_test.dart` and `database_backup_service_test.dart` contended for `pak_connect.db` | Superseded failure evidence |
| CI-race correction and publication gate | Commit `569ff9a` preserves each suite's isolated test database; PR #73 must pass required exact-head Flutter and CodeQL contexts before merge | Protected PR gate |
| Android device matrix | No phone attached | Device-gated |
| SQLCipher at-rest proof | Desktop loader falls back to plaintext | Device-gated |

Desktop logs can contain expected SQLite loader fallback notices and explicit
plaintext-test events. Those are known harness behavior; they must not be
mistaken for production encryption evidence.

## Earlier reconciliation hardening (through `5a2cb8e`)

| Area | Result |
|---|---|
| Queue-sync response identity | Random echoed `syncId` binds a response to one live round; peer-controlled aliases cannot complete another target's request |
| Already-synced round | Responder now emits a correlated response instead of leaving the initiator to time out |
| Targeted BLE writes | Fragment budget comes from the selected client/server route, never an unrelated global client MTU |
| Route disappearance | A queued non-handshake write completes with error; queue-sync fails fast instead of reporting success then timing out |
| Strict TDM | MTU/notify/handshake/disconnect milestones carry an attempt generation; stale peer/attempt events, timeout and failure cleanup cannot release or erase a newer attempt |
| Handshake attribution | Completion uses the peer bound when that handshake started, not the first unrelated client or whichever link became active later |
| Resume delivery | Session, ephemeral and persistent aliases survive backlog prefiltering; final per-message recipient gate remains in place |
| Active link inventory | Facade exposes all deduplicated client and server addresses |
| Manual reconnect | Facade reaches the working connection-manager service scan instead of a permanent-null discovery placeholder |
| Inbound failure signal | Typed `InboundMessageProcessingException` replaces a plaintext sentinel collision |
| Fragment wire ID | Random transport IDs avoid the old truncated-ID reassembly collision |
| Fragment reassembly | Metadata is pinned; indexes/mode/base64 are validated; duplicate conflicts poison/clear; active, per-message and aggregate memory are bounded |
| Text fragmentation | UTF-8 bytes are base64-fragmented; Unicode and pipe content round-trip inside the negotiated MTU |
| Queue response mutation | Tokenless, replayed or wrong-address responses return an error before adding/reverse-sending any queued payload |
| Direct queue route isolation | Direct queued payloads require one active BLE route; sync-triggered payloads must name that exact sole address; ambiguous multi-link sends defer safely |
| Message ACK ownership | The write adapter shares the handler tracker completed by inbound ACK dispatch; peripheral sends now wait for ACK and the queue no longer starts an unwired second tracker |
| Final relay delivery | The recipient decodes the signed encrypted v2 inner `ProtocolMessage`, authenticates/decrypts and persists it before the routed relay ACK; processing failure produces no ACK and no seen mark; a duplicate completed delivery resends the ACK without redelivery |
| Archive detail | Archive list and inline search results open persisted archive/message detail instead of a fabricated empty archive |
| Mark unread | HomeScreen and interaction-service actions persist an unread marker and refresh the chat list |
| Change-log scope | Production gossip no longer composes the metadata-only peer-replay prototype; local capture/export/import/pruning remain active and peer cursors cannot advance |
| Friend-reveal verification | Split dispatch cannot emit an unverified identity; the authenticated handler checks the signed challenge, ±5-minute timestamp, cached pairing and exact contact-key binding |
| Friend-reveal action | Reveal frames require one unambiguous BLE route and transport success; UI navigation uses a typed verified-key/`ChatId` snapshot that remains safe after disconnect and with duplicate names |
| Broadcast-list truth | The former group UI is now a reachable Broadcast Lists surface; it queues ordinary direct messages by canonical `chatId`, renders own/peer records correctly, and does not claim a shared recipient conversation or delivery receipt |
| Reachability cleanup | Enforced audit passes with 437 libraries: 433 runtime-reachable and four reviewed test-only candidates; 44 unjustified libraries and their island-only tests were removed |
| Tooling cleanup | Orphan root Node/MCP research manifests were removed; they were not Flutter runtime or CI dependencies |
| Documentation portability | Local Markdown link audit reports zero broken relative targets; machine-specific compressed-checkpoint links were replaced with canonical links or explicit historical provenance |
| Fragment cleanup determinism | Expiry uses an inclusive boundary, so zero-timeout cleanup cannot retain an assembly created in the same clock tick |
| Widget harness teardown | App shell tests use a lightweight connection contract mock, hold initialization at the loading boundary, and unmount providers before closing streams; full-suite workers no longer hang |

## Subsequent local hardening (through `53bb4fe`)

| Area | Result |
|---|---|
| Archive deletion | Repository and UI/service flows serialize durable delete ownership; success is not published before the archive row is gone |
| Archive restoration | One owner performs strict decode, conflict validation, live reconstruction and archive deletion in a single transaction; rollback preserves both sides |
| Automatic reconnect | Power-cycle/health retries preserve and scan only for the prior platform peripheral UUID; missing/rotated targets fail closed rather than dialing the first advertiser |
| Runtime rebootstrap | Initialization generations prevent a disposed/older AppCore attempt from publishing services or cleaning up a newer attempt |
| Queue availability | Production queue initialization/load/write failures reject admission; volatile fallback requires an explicit test/relay policy |
| Relay ACK route | Routed acknowledgements are bound to the authenticated inbound route and cannot complete unrelated relay ownership |
| Durable queue ownership | Pending-to-sending admission, recovery, retry, ACK/delete and post-dispose finalization use conditional `(status, attempts, lastAttemptAt)` ownership; covered old/new instances cannot overwrite, delete or resurrect each other |
| Peer-synced insertion | One transaction admits a peer row only when neither an active row nor durable tombstone owns its message ID |
| Queue-sync receipts | Transport callbacks return exact durably admitted IDs; absent, empty, partial or unexpected receipts fail the round |
| Physical write route | Central/peripheral sends pin connection incarnation plus physical peer/characteristic handles, revalidate inside one shared GATT lane, and start ACK timing only when the scheduled write executes |
| Parallel database tests | Suite-specific database names survive helper tests, eliminating the two known shared-`pak_connect.db` CI collisions locally |

## Current baseline delta (`ed4d416..7944c93`)

| Commit | Result |
|---|---|
| `db529df` | Android notification naming and UI state the actual boundary: the handler posts to the system tray while PakConnect is running; it does not claim killed-process receipt or native background execution |
| `eccced7` | CI and package authority use Flutter 3.44.4 with lockfile-enforced dependency resolution; Android preserves `android.builtInKotlin=false` and `android.newDsl=false` compatibility flags pending a separate toolchain migration |
| `5142358` | Archive compression requests fail honestly to uncompressed storage instead of claiming savings while retaining the original rows |
| `d584f44` | Public-facing Flutter template labels and descriptions use PakConnect branding while package and binary identities remain stable |
| `7944c93` | Dormant BLE contract seams and their ownership limits are labeled accurately; this exact runtime/build-input tree is the current verified device baseline |

## Confirmed live capabilities

- Flutter/Riverpod application bootstrap with layered services.
- Dual-role BLE architecture (central and peripheral).
- Noise XX/KK implementation and desktop regression coverage.
- Direct encrypted messages, offline queue, acknowledgements and retries.
- Mesh relay/dedup/hop policy and queue-sync coordination.
- Authenticated final-relay delivery with persistence-before-ACK and idempotent
  duplicate ACK behavior in desktop regression coverage.
- SQLCipher-capable mobile database path, schema v12 and migrations.
- Contacts, chats, sender-local broadcast lists, archive/search models and UI
  surfaces. Broadcast recipients receive ordinary direct-chat messages.
- Background-resume backlog reprocessing on the Dart lifecycle path.

## Not yet proven or intentionally incomplete

- Two physical Android devices completing discovery, collision handling,
  Noise handshake and bidirectional delivery.
- Device SQLCipher file unreadability without the derived key.
- Native iOS/Android background execution while the process is suspended.
- Live change-log transport/replay is intentionally disabled. Production
  gossip does not instantiate or invoke the metadata-only prototype;
  change-log remains local capture/export/import/prune only.
- Release signing and installable release APK.
- Multi-peer manual reconnect selection; current scan returns the first
  PakConnect service advertiser.
- Multi-link user-payload delivery. Control frames are address-targeted, but
  direct queue payloads deliberately defer when more than one link is live
  until per-link handshake identity and ACK bindings exist.
- A true synchronized group protocol. Broadcast lists intentionally have no
  group ID on the wire, membership synchronization, shared transcript/reply
  path, group key or owner/admin model.

## Immediate sequence

1. Close PR #73 only after fresh Flutter and both CodeQL checks pass on its
   exact final head, then verify the resulting protected `main`.
2. Use runtime/device baseline `7944c93` as the device-evidence ID.
3. Install its debug APK and execute
   `docs/testing/TWO_ANDROID_DEVICE_EXECUTION_CHECKLIST.md` when two phones are
   available.
4. Complete the SQLCipher-at-rest proof on a production-like Android build.
5. Supply/verify release signing and build/install the signed release APK.
6. Design per-link handshake identity and ACK binding before enabling
   multi-link user-payload delivery.
7. Attach every hardware result and redacted log reference to
   `docs/testing/DEVICE_VALIDATION_STATUS.md`.
