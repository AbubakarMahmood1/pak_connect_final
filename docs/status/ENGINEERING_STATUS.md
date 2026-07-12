# PakConnect engineering status

Last updated: 2026-07-13

## Current verdict

The canonical source is reconciled, statically clean, green across the full
desktop suite, and produces an Android debug APK. The post-patch suite passes
5,539 tests; the lower count versus the 5,748 baseline is explained by the
deliberate removal of six isolated dead implementations and their dedicated
test clusters, with later focused regressions added. Real BLE,
SQLCipher-at-rest, native background behavior,
release signing and installation remain device/environment-gated, so this is
not yet a signed or hardware-validated release.

## Authority and preservation

- Canonical remote: `AbubakarMahmood/pak_connect`.
- The compressed working copy was checkpointed before reconciliation.
- Active reconciliation branch: `codex/reconcile-pakconnect`.
- Verified code/build-input device-test baseline:
  `9cccd014c7bb93d0a3aab26aaf7674c3a5192dd3` (`9cccd01`). A
  documentation-only descendant is acceptable only when its build-input diff
  from this commit is empty.
- The former baseline `a5c2b08` (`fix: harden runtime and prune unreachable
  code`) and its test/APK hashes remain historical provenance, not the baseline
  for the next device run.
- Candidate `fcb3013` is also historical: Flutter 3.44 analysis required an
  equivalent null-aware syntax cleanup, which is included in `9cccd01`.
- The reconciled history contains the mainline plus the preserved runtime,
  guidance, two-device-prep and Fable audit commits.
- Do not use the compressed copy for new work; it is recovery evidence only.

## Verification ledger

| Check | Evidence | Status |
|---|---|---|
| Flutter/Dart toolchain | Flutter 3.41.5 stable, Dart 3.11.3 | Green |
| Static analysis before current patch | `flutter analyze --no-pub` | Green |
| Pre-patch full desktop suite | 5,748 tests, 0 failures, about 4m42s | Green baseline |
| Current static analysis | `flutter analyze --no-pub`, clean on 2026-07-13 | Green |
| Dart reachability enforcement | 437 libraries; 433 runtime, 4 reviewed test-only, 0 unreviewed | Green |
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
| Current full desktop suite | 5,539 tests, 0 failures, 5m20s; 9,515,985-byte `flutter_test_latest.log`, SHA-256 `152F6CABA2083675728A7F0A1CDEF6CEA20AA7BDECFE96BDD4C912AE2BAE53FE` | Green |
| Android debug APK | 203,988,403 bytes; SHA-256 `3A0B32EBBB8255C539C62BDD6ACA077108BC5EEF0D431AAEBA5232FB64E28B50` | Green build |
| Android device matrix | No phone attached | Device-gated |
| SQLCipher at-rest proof | Desktop loader falls back to plaintext | Device-gated |

Desktop logs can contain expected SQLite loader fallback notices and explicit
plaintext-test events. Those are known harness behavior; they must not be
mistaken for production encryption evidence.

## Promoted hardening in the current patch

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

1. Use code baseline `9cccd01` (or its documentation-only descendant) as the
   device-evidence ID.
2. Install its debug APK and execute
   `docs/testing/TWO_ANDROID_DEVICE_EXECUTION_CHECKLIST.md` when two phones are
   available.
3. Complete the SQLCipher-at-rest proof on a production-like Android build.
4. Supply/verify release signing and build/install the signed release APK.
5. Design per-link handshake identity and ACK binding before enabling
   multi-link user-payload delivery.
6. Attach every hardware result and redacted log reference to
   `docs/testing/DEVICE_VALIDATION_STATUS.md`.
