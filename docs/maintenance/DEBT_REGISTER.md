# PakConnect debt register

Last reconciled: 2026-07-14

This register contains confirmed liabilities that are not silently promoted as
working features. `Now` means required before the current FYP/portfolio
readiness gate; `Later` is bounded and accepted; `Investigate` needs evidence
before a design decision.

| ID | Priority | Status | Liability and evidence | Decision / exit condition |
|---|---|---|---|---|
| DEBT-CI-001 | P1 | Now/publication | Public-main Flutter run `29215130687` failed two parallel suites with SQLite `database is locked`. Local commit `4fd8aec` preserves suite-specific database names and the local full suite is green, but the current hardening chain is not on GitHub. `main` has no protection/ruleset, and PR #72 merged before its checks completed | Protect `main`, require pull requests plus `test`, Android CodeQL and Actions CodeQL, publish through a normal non-force PR, and close only when exact-head PR checks plus the post-merge main run pass |
| DEBT-ANDROID-BUILD-001 | P2 | Later/tooling | Flutter 3.44.4 builds remain compatible but warn that Gradle 8.11.1 should move to 8.14+, Android Gradle Plugin 8.9.1 to 8.11.1+, and Kotlin 2.1.0 to 2.2.20+; Flutter also flags a future built-in Kotlin/plugin migration | Preserve the current verified build inputs for this baseline; perform the coordinated Gradle, AGP, Kotlin, and built-in-Kotlin/plugin migration in a separate compatibility-tested change |
| DEBT-DEPS-LICENSE-001 | P2 | Later/maintenance; Now/release audit | On 2026-07-14, `puro --no-progress -e ci-3-44-4 flutter pub outdated --no-dev-dependencies` reported 22 outdated direct-dependency rows, 45 dependencies locked below an upgradable version, and 13 constraints below a resolvable version. The root license is proprietary, but no exact-release SBOM/dependency-license inventory, bundled notices set, or jurisdiction-specific cryptography distribution review is retained | Upgrade dependencies in bounded compatibility-tested groups rather than changing the verified baseline opportunistically. Before distributing a release, generate the inventory from its exact lockfile, review every bundled license/notice and applicable crypto/export obligation, ship the required notices, and retain the review artifact |
| DEBT-SYNC-001 | P2 | Later | Live change-log replay is intentionally disabled; the dormant prototype carries metadata rather than full rows and has no authenticated transport or convergence contract | Enable only with row payloads, exact authenticated peer routing, partial-failure cursor rules and convergence tests; keep local capture/export/import/prune meanwhile |
| DEBT-BG-001 | P1 | Later/device | Resume hook flushes pending messages, but there is no native Android WorkManager/service or iOS BGTask execution | Do not claim background delivery while suspended; choose platform design only after device lifecycle evidence |
| DEBT-SQLCIPHER-001 | P1 | Device | Desktop tests fall back to plaintext SQLite; no current at-rest device proof | Complete the SQLCipher device proof in the validation ledger |
| DEBT-ARCHIVE-COMP-001 | P2 | Later | Archive/search/restore currently depend on individually persisted encrypted message rows. A compression request above 10 KiB is now reported honestly as `Archive compression is not implemented; stored uncompressed`; there is no canonical compressed-byte schema, migration, encryption/search/restore path, or exact stored-size accounting | Keep `isCompressed` false and savings at zero until compressed bytes become the canonical persisted representation. Close only with schema/migration, encryption, search/index, restore, deletion and exact-size tests plus compatibility with existing uncompressed archives |
| DEBT-ARCHIVE-POLICY-001 | P2 | Later | `AutoArchiveScheduler` is implemented, wired by `AppCore`, preference-controlled and tested for in-process inactivity archiving. It is separate from the advanced `ArchivePolicyEngine`, whose policy application/selection and validation/conflict logic are placeholders, and `ArchiveMaintenance`, whose cleanup, index rebuild, compression and expiry tasks report zero work; maintenance-history persistence is also a no-op | Keep the inactivity scheduler claim limited to a live app process. Implement policy and maintenance work one operation at a time with repository effects, truthful result/error accounting, restart/idempotency tests and user-visible retention semantics; add native scheduling only if killed/doze execution becomes a requirement |
| DEBT-QUEUE-LINK-001 | P1 | Later/device | Queue-sync payloads now preflight one exact address, pin the physical peer/characteristic through the serialized GATT write, and start ACK timing only when that write executes. Direct queued delivery still fails closed unless one unambiguous link is active, and physical multi-link identity/ACK isolation is unproved | Record `address + connection generation -> verified ephemeral/persistent aliases + Noise-ready` at handshake completion, clear it on exact disconnect, permit concurrent-link delivery only through that binding, and prove A/B isolation with a third device |
| DEBT-QUEUE-REV-001 | P3 | Investigate | Durable delivery ownership compares `(status, attempts, lastAttemptAt)`. Normal attempts change that token and reset/rebootstrap races are covered, but manual retry can restore `pending/0/null`, so a contrived overlapping-instance ABA cycle is not formally excluded | Add a durable monotonic row revision or attempt UUID only if lifecycle/concurrency evidence exposes the ABA; retain message-ID deduplication and the current CAS handoff meanwhile |
| DEBT-RECONNECT-001 | P2 | Later | Manual reconnect now works but selects the first PakConnect service advertiser, not a requested contact | Add target hint/contact filtering before claiming reliable multi-peer manual reconnect |
| DEBT-RECONNECT-UUID-001 | P1 | Device | Automatic reconnect is fail-closed to the previously connected platform peripheral UUID, but Android may rotate that UUID across Bluetooth off/on; no physical trace proves stability or the safe-timeout path | On both phones record the platform UUID before/after Bluetooth cycling. If it rotates, automatic reconnect must ignore other advertisers and time out until a manual identity-verified reconnect; never fall back to the first advertiser |
| DEBT-BLE-GEN-001 | P2 | Device | BLE plugin inbound events expose address but no native connection generation | Validate same-address rapid reconnect on hardware; upstream/extend plugin if delayed old-link events can cross a new connected event |
| DEBT-BLE-API-001 | P2 | Investigate | Dormant BLE contract methods remain exposed: `BLEDiscoveryService.scanForSpecificDevice()` and `buildLocalCollisionHint()` return `null`; the live facade bypasses the former through `BLEConnectionManager` and obtains collision hints from `BLEHandshakeService`. `BLEHandshakeService.handleMutualConsentRequired()` and `handleAsymmetricContact()` are facade-exposed no-ops with no production caller found. The source now labels these seams explicitly, and the previously stale Phase 3B adapter marker was corrected because `BLEMessageHandlerFacadeImpl` already exists. Whole-library reachability still cannot prove individual members live | After two-device stabilization, remove unused contract members or implement them only with a named production caller and focused facade/device evidence; retain the currently wired connection-manager, handshake and message-handler-facade paths in the meantime |
| DEBT-GROUP-001 | P2 | Later | The shipped feature is now honestly bounded as sender-local broadcast lists: recipients get ordinary direct messages, with no group ID on the wire, synchronized membership, shared transcript/replies, or correlated broadcast receipts | Keep the current label and fail-safe direct-message behavior; implement a true group protocol only with authenticated membership/versioning, inbound persistence/dedup, reply/admin rules, mixed-version handling, and device tests |
| DEBT-DI-001 | P2 | Investigate | Some services retain static resolver/service-locator fallbacks beside constructor DI | Migrate opportunistically when touching an owner; do not create a broad DI rewrite |
| DEBT-FRAG-001 | P3 | Accepted | Legacy fragment envelope has no independent CRC | Noise authenticates encrypted traffic and conflicting duplicates are rejected; add checksum only if an unauthenticated transport use case is retained |
| DEBT-RELAY-PRIV-001 | P1 | Later/device | All live outgoing relay callers omit `sealedSender`, no runtime caller generates a stealth envelope, and the production relay factory injects no `MessageCostPolicy`, so PoW is not enforced | Public claims are corrected; enable any feature only through an explicit policy backed by privacy, mixed-version, abuse, performance, and two-device tests |
| DEBT-PLATFORM-001 | P3 | Environment | Windows desktop build cannot run here because Visual Studio is absent | Not an Android release blocker; validate if Windows is a claimed target |

## Closed in the 2026-07-10 through 2026-07-13 hardening passes

- Queue responses can no longer complete the wrong target's pending round via
  a claimed node ID or global alias.
- Queue delivery admissions, recovery, retry and post-dispose finalization use
  conditional durable ownership; stale instances cannot overwrite, delete or
  resurrect a successor attempt in the covered old-wins/successor-wins races.
- Peer-synced queue rows are inserted atomically only when neither an active row
  nor a durable deletion tombstone exists.
- Queue-sync payload receipts now follow exact durable transport admissions;
  central/peripheral route handles are revalidated at the serialized physical
  write without consuming ACK timeout while waiting for that lane.
- Already-synchronized queue rounds emit a response.
- Tokenless/uncorrelated responses cannot mutate queues or trigger reverse send.
- Direct queue payloads fail closed on ambiguous multi-link state; central and
  peripheral sends share the inbound ACK tracker and return ACK truth.
- Targeted writes use the selected route's MTU and fail on route loss.
- Strict-TDM milestones and cleanup are attempt-bound.
- Resume delivery recognizes session/ephemeral/persistent aliases.
- Active link IDs include every client and server route.
- Manual reconnect no longer delegates to a permanent-null placeholder.
- Inbound structural failure uses a typed exception, not a plaintext sentinel.
- Fragment IDs are collision-resistant and reassembly state is validated and
  bounded.
- Archive/search results open persisted archive detail.
- Mark-unread persists and refreshes in both HomeScreen interaction paths.
- Production gossip no longer instantiates or invokes metadata-only change-log
  peer replay; local capture/export/import/prune remains active.
- Friend reveal is verified only in the authenticated handler, binds the
  claimed key to the contact's chat identity, rejects stale/future proofs, and
  routes `VIEW` by a typed stable snapshot even after disconnect.
- Friend reveal transport reports success only after one unambiguous BLE route
  accepts the protocol frame.
- The former group surface is labeled and documented as Broadcast Lists;
  sender/peer rendering uses the exact local key and queue acceptance is not
  misreported as recipient delivery or a shared conversation.
- Security, testing, SRS, CI and runtime docs now distinguish implemented
  behavior, historical targets and device-gated claims. No numeric coverage
  threshold or device CI job is claimed.
- Whole-library reachability enforcement passes at 437 libraries: 433 runtime
  reachable and four explicitly reviewed test-only candidates. Forty-four
  unjustified libraries and six island-only test clusters were removed.
- The orphan root Node/MCP research manifests were removed; Flutter remains the
  only project runtime/toolchain manifest at the repository root.
- The device runner uses the selected Flutter APK path and validates release
  signing before build/install.
- Payload-preview logging outside the fragmenter was removed.

## Triage rule

Promote a row to `Now` only with a concrete failure, misleading product claim,
security/reliability gate, or demo-visible defect. Large architectural ideas
stay `Investigate` until a narrow test or measurement proves the benefit.
