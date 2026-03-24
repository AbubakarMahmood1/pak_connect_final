# Crypto Redesign Roadmap (Validated)

**Date**: 2026-03-23  
**Status**: Drafted from validated repo state  
**Goal**: Evolve PakConnect toward a production-grade security architecture without blocking progressive delivery.

---

## 1) Validated Current State

This roadmap is based on current code paths, not generic advice:

- Multi-method crypto selection still exists in runtime policy:
  - `lib/core/services/security_manager.dart`
  - Active runtime method set is now `noise`, `ecdh`, and `pairing`.
  - Legacy/global remains only as an explicit migration-only decrypt
    compatibility lane.
- Noise sessions are implemented and hardened (nonce locking, replay checks, rekey thresholds), but this is not a Double Ratchet:
  - `lib/core/security/noise/noise_session.dart`
  - `lib/core/security/noise/noise_session_manager.dart`
  - `lib/core/security/noise/noise_encryption_service.dart`
- Outbound send is fail-closed for legacy/global encrypt path, and decrypt
  compatibility paths keep legacy/global handling behind explicit policy:
  - `lib/core/services/security_manager.dart`
- Message signing currently uses ECDSA P-256 (including ephemeral low-trust signing), not Ed25519:
  - `lib/domain/services/signing_manager.dart`
- SQLCipher open path currently applies DB password on mobile platforms:
  - `lib/data/database/database_helper.dart`

Conclusion: current system is functional, but crypto complexity and fallback breadth are the primary long-term risk.

---

## Progress Snapshot (2026-02-12)

- Pass A foundation is implemented in code:
  - canonical `CryptoHeader` model added.
  - protocol `v2` encrypted decrypt path is deterministic by declared `crypto.mode`.
  - explicit legacy fallback gate is limited to `v1` handling.
- Logging/RNG hardening completed:
  - pairing code uses `Random.secure()`.
  - pairing code values are no longer logged.
  - pairing dialog controller log no longer prints live PIN values.
  - `print(...)` removed from `lib/**` runtime code (doc comments excluded).
- Runtime hygiene gates added to CI:
  - no non-comment `print(...)` in `lib/**`.
  - `Timer.periodic(...)` count regression gate capped at current baseline.
- Strict crypto policy gate added to CI:
  - targeted fail-closed transport tests now run via
    `scripts/crypto_policy_gate.ps1`.
  - gate currently enforces:
    - removed legacy v2 transport modes are rejected on send.
    - sealed v1 fallback is used when recipient static Noise key exists.
    - sealed v2 inbound sender-binding requirement (no transport fallback).
    - inbound encrypted v2 signature requirement in both text handler paths.
    - inbound rejection of unsigned v2 direct plaintext text messages.
    - upgraded peers continue to reject removed legacy transport headers.
- Pass B correctness hardening added:
  - outbound encryption now executes by the preselected method type via
    `ISecurityService.encryptMessageByType(...)`.
  - v2 header mode and actual encryption path are now coupled by a single
    decision source.
- Pass A authenticity hardening added:
  - v2 signatures now cover a canonicalized envelope payload (version/type/
    sender/recipient/messageId/crypto/content) instead of plaintext-only.
  - inbound signature verification for v2 now verifies that canonical envelope.
  - strict signature policy gate added for encrypted v2 text messages:
    `PAKCONNECT_REQUIRE_V2_SIGNATURE=true` rejects unsigned encrypted v2
    payloads in both inbound handlers.
  - adversarial regression coverage added for both inbound handlers:
    - `test/data/services/protocol_message_handler_test.dart`
    - `test/data/services/inbound_text_processor_test.dart`
    - verifies valid v2 signed envelope passes and `crypto.mode` tampering with
      reused signature fails as untrusted.
- Pass D downgrade guard started:
  - runtime protocol-floor tracking added for inbound text handlers.
  - once a peer is observed on v2, subsequent v1 from that peer is rejected
    (feature-gated by `PAKCONNECT_ENFORCE_V2_DOWNGRADE_GUARD`, default `true`).
  - guard state is now centralized in a shared runtime component
    (`PeerProtocolVersionGuard`) so all inbound handlers enforce the same floor.
- Pass D stale-event suppression increment:
  - `NoiseSessionManager` now resets responder in-flight state on duplicate
    handshake-1 packets instead of tearing down the session as a hard failure.
  - covered by
    `test/core/security/noise/noise_session_manager_test.dart`.
  - established sessions explicitly ignore stale/replayed handshake-1 packets
    (now regression-tested).
  - reconnect cleanup and fresh re-establishment flow are now regression-tested.
  - message-limit rekey threshold behavior is now regression-tested
    (session marked for rekey at 10k sends, 10,001st send fails closed).
- Pass B compatibility-tightening completed:
  - inbound v2 transport accepts only active modes.
  - removed legacy transport headers (`legacy_ecdh_v1`,
    `legacy_pairing_v1`, `legacy_global_v1`) are rejected deterministically.
- Pass B peer-upgrade send policy tightening added:
  - outbound no longer emits legacy v2 transport modes.
  - if an old ECDH/pairing contact path is encountered, outbound now
    auto-attempts `sealed_v1` fallback when recipient sealed prerequisites are
    available and otherwise fails closed.
- Pass B peer-upgrade decrypt policy tightening added:
  - inbound removed legacy transport headers are rejected for peers already
    observed at protocol floor v2+.
  - implemented in:
    - `lib/data/services/protocol_message_handler.dart`
    - `lib/data/services/inbound_text_processor.dart`
- Pass B peer-upgrade signature policy tightening added:
  - inbound encrypted v2 messages now require a signature for peers already
    observed at protocol floor v2+, even when global strict-signature mode is
    disabled.
  - implemented in:
    - `lib/data/services/protocol_message_handler.dart`
    - `lib/data/services/inbound_text_processor.dart`
  - regression coverage:
    - `test/data/services/protocol_message_handler_test.dart`
    - `test/data/services/inbound_text_processor_test.dart`
- Sender identity resolution split by purpose:
  - decrypt path can still resolve Noise session IDs where required.
  - signature path resolves stable identity keys (persistent/public), avoiding
    session-id misuse as a verification key.
- Pass C scaffold started:
  - added `sealed_v1` crypto primitive service:
    `lib/core/security/sealed/sealed_encryption_service.dart`
  - added deterministic unit tests for:
    - roundtrip success
    - wrong-recipient decrypt failure
    - ciphertext tamper failure
    - AAD mismatch failure
- outbound removed-legacy fallback now supports sealed send whenever recipient
  static Noise key material is available.
- when sealed send prerequisites are present, outbound now prefers `sealed_v1`
  over removed legacy transport methods for offline-eligible sends.
- inbound sealed decrypt path is now wired for v2 handlers via
  `ISecurityService.decryptSealedMessage(...)`.
- inbound sealed v2 sender/recipient envelope binding is now strict:
  - `senderId` must be explicitly present in the message envelope.
  - transport sender fallback is no longer accepted for sealed decrypt.
  - covered by negative-path tests in:
    - `test/data/services/protocol_message_handler_test.dart`
    - `test/data/services/inbound_text_processor_test.dart`
- binary payload handling now fails closed on decrypt failure (drop instead of
  forwarding undecrypted bytes to downstream callbacks).
- binary payload sender-key resolution is now deterministic per transport
  identity:
  - decrypt attempts use a single ordered candidate set (contact session key,
    persistent key, contact public key, transport key).
  - removed ad-hoc "retry transport sender after resolved-sender failure"
    branching in binary decrypt flow.
- v2 plaintext spoofing policy tightened for text messages:
  - direct plaintext v2 text messages are rejected.
  - plaintext broadcast v2 text messages now require a valid signature.
  - enforced in both inbound text handling paths.
- `legacy_global_v1` is now hard-blocked for v2 inbound decrypt routing.
- downgrade-floor poisoning mitigation:
  - peer protocol floor now advances only for authenticated v2 messages
    (or legacy v1 flow), not from unauthenticated v2 traffic.
- envelope binding regression coverage expanded:
  - tamper-matrix tests now verify signature rejection when these fields change:
    - `senderId`, `recipientId`, `messageId`, `content`
    - `crypto.mode`, `crypto.sessionId`, `crypto.kid`, `crypto.epk`, `crypto.nonce`
  - tests:
    - `test/data/services/protocol_message_handler_test.dart`
    - `test/data/services/inbound_text_processor_test.dart`
- local Noise static private key accessor now has an explicit defensive-copy
  invariant test:
  - `test/core/security/noise/noise_encryption_service_test.dart`

## Implementation Checkpoint (2026-03-23)

- `SimpleCrypto` is now an active-crypto convenience facade for tests and
  compatibility shims, not the runtime owner for all crypto paths.
- Responsibility split now exists across dedicated services:
  - `ConversationCryptoService`: pairing/session conversation payload helpers
  - `ContactCryptoService`: contact-targeted ECDH payload helpers
  - `PairingCryptoService`: pairing/shared-secret lifecycle, cache restore,
    and contact-upgrade crypto orchestration
  - `SigningCryptoService`: signing and shared-secret derivation
- Active outbound encryption selection no longer uses `global` as a normal
  send mode. If no live method is available, outbound fails closed.
- Legacy/global decrypt support has been removed from runtime. Unknown or old
  global payloads now fail closed and trigger normal resync/error handling.
- Normal runtime decrypt ordering now tries only active lanes
  (`ecdh`/`pairing`/`noise`).
- Repo guardrails now enforce that new runtime `lib/**` code does not add fresh
  direct `SimpleCrypto.` call sites outside the compatibility facade.
- Pairing/contact-upgrade flows now route shared-secret caching and runtime
  conversation-key restore through `PairingCryptoService` instead of directly
  mixing `ConversationCryptoService` and `SigningCryptoService` calls inside
  controllers.
- `CryptoVerificationService` now owns diagnostic/self-test helpers that used
  to live under `SimpleCrypto`, further shrinking the transitional facade.

### Legacy Compatibility Removal Result

The legacy/global compatibility lane has now been removed. The repo no longer
ships:

- `LegacyPayloadCompatService`
- `LegacyCryptoMigrationPolicy`
- `PAKCONNECT_ALLOW_LEGACY_COMPAT_DECRYPT`
- any runtime decrypt fallback that treats `global` payloads as supported

Remaining legacy/global markers are retained only where useful as explicit
unsupported sentinels in tests or wire parsing logic.

---

## 2) Target End State (Best of Both Worlds)

Use a dual-lane model with one unified envelope policy:

- **Live lane**: interactive Noise session transport.
- **Offline lane**: asynchronous prekey/sealed-style payload for store-and-forward.
- **Single envelope contract**: explicit algorithm/mode ID per message, fail-closed decrypt by declared mode only.
- **Optional advanced lane**: add Double Ratchet over live sessions later.

This preserves:

- Strong live-session security properties.
- Reliable offline/mesh delivery behavior.
- Lower complexity than keeping many parallel legacy paths permanently active.

---

## 3) Progressive Passes (0% -> 100%)

### Pass A (0-15%): Envelope + Policy Hardening

- Introduce explicit `crypto_mode` metadata in protocol envelope.
- Decrypt only by declared mode (remove implicit trial-and-error for new-format messages).
- Keep legacy decrypt path behind explicit compatibility gate/version.

**Exit criteria**

- New messages always include mode/version.
- Decrypt logic is deterministic for new versions.
- Compatibility metrics/logging available for legacy payload reads.

**Status**: Completed on `2026-02-12` (follow-up threat-model review now high ROI).

### Pass B (15-35%): New-Send Path Simplification

- New outbound send path uses only:
  - `noise_session` when session exists.
  - `async_prekey` when no live session exists.
- Remove new-send dependence on `global` and ad-hoc legacy fallback selection.

**Exit criteria**

- No new outbound payload is produced with legacy/global mode.
- Fallback logic only applies to old incoming messages.

**Status**: Completed (`2026-03-24`).

Implemented now:
- strict policy gate exists for outbound rejection of removed legacy transport
  modes.
- outbound v2 `crypto.mode`/`sessionId` metadata now derives from
  `ISecurityService.getEncryptionMethod(...)` (not local heuristics),
  reducing header/method mismatch risk.
- outbound encryption now uses `ISecurityService.encryptMessageByType(...)`
  with the same resolved method used for metadata, removing dual-path drift.
- runtime decrypt ordering no longer treats removed legacy/global transport as a
  normal per-security-level method.
- legacy v2 transport emission and decrypt fallback have been deleted.

### Pass C (35-55%): Offline Async Prekey Lane

- Implement one-shot recipient decryptable payload lane for offline/store-forward.
- Keep sender auth explicit and verifiable in the envelope.

**Exit criteria**

- Offline recipient can decrypt without prior interactive handshake.
- Relay path remains opaque to plaintext.
- Replay controls and message ID semantics remain deterministic.

**Status**: In progress (`2026-02-12`).

Implemented now:
- sealed/offline cryptographic primitive service and core invariants are in
  place via `test/core/security/sealed/sealed_encryption_service_test.dart`.
- outbound v2 now switches removed legacy send attempts to `sealed_v1` when a
  recipient static Noise key is available.
- outbound now prefers `sealed_v1` before any removed legacy transport method
  when offline prerequisites are available.
- inbound v2 handlers route `sealed_v1` to dedicated sealed decrypt logic
  (no legacy fallback guessing for sealed mode).
- binary payload processing is now fail-closed when decrypt fails.
- relay-aware inbound text tests now verify transport sender is not used as
  cryptographic sender for v2 decrypt/signature routing paths:
  `test/data/services/inbound_text_processor_test.dart`.

Remaining:
- expand to device-level multi-hop validation for live relay routes.

### Pass D (55-75%): Live Session Lifecycle Hardening

- Tighten session ownership/rekey orchestration.
- Enforce strict stale-event suppression and downgrade policy.
- Strengthen failure semantics (no silent weaker-mode drift).

**Exit criteria**

- Session transitions deterministic under reconnect/drop/out-of-order conditions.
- Rekey behavior tested in long-running session simulations.

**Status**: In progress (`2026-02-12`).

Implemented now:
- downgrade protocol floor policy centralized and shared across inbound handlers.
- cross-handler coverage added proving a v2 observation in
  `ProtocolMessageHandler` blocks later v1 downgrade in `InboundTextProcessor`.
- duplicate/stale responder handshake-1 retransmits no longer hard-fail the
  in-flight session state machine.
- stale handshake-1 packets are now ignored while initiator session is active
  and after session establishment.
- reconnect cleanup + re-establishment flow is now covered in session-manager
  tests.
- rekey threshold behavior is now covered in session-manager tests:
  - rekey marker appears at 10k sent messages.
  - additional sends fail closed until rekey.
- direct Noise session coverage now also enforces message-limit rekey behavior
  (`test/core/security/noise/noise_session_test.dart`), validating stats and
  fail-closed encryption after 10k sends.
- direct Noise session coverage now enforces time-limit rekey behavior using a
  deterministic test clock (1 hour threshold), validating `needsRekey` and
  fail-closed encryption after expiry.

Remaining:
- time-based rekey and extended reconnect/drop/out-of-order simulations beyond
  unit test scope.

### Pass E (75-90%): Optional Double Ratchet

- Add ratchet for live session messages.
- Keep async prekey lane for offline bootstrap.

**Exit criteria**

- Ratchet state persistence/recovery and skipped-key limits validated.
- Interop and migration plan documented.

### Pass F (90-100%): Migration + External Assurance

- Deprecation switches, compatibility window closure plan.
- Comprehensive invariant tests, fuzz/property tests, and third-party review.

**Exit criteria**

- Legacy path disabled (or tightly allowlisted).
- Security invariants enforced in CI and release checklist.

---

## 4) Risk Model

Primary risks:

- Crypto split-brain (multiple active mechanisms with ambiguous policy).
- Silent downgrade/compatibility drift.
- Session state complexity during mesh/offline transitions.
- Signature/identity ambiguity across trust modes.

Mitigations:

- Single envelope policy + strict mode routing.
- Compatibility gates with expiration.
- Phase-specific invariant tests (not just unit behavior tests).
- Explicit release criteria per pass.

---

## 5) Timeline Interpretation (Important)

The earlier "1-2 week / 2-3 week" ranges are **engineering calendar estimates** for:

- design decisions,
- implementation,
- migration compatibility,
- tests (unit/integration/device),
- review and hardening.

They are **not** estimates of "how fast Codex can type code."

Why your prior passes moved faster:

- DI passes were primarily architecture and wiring refactors.
- Crypto redesign introduces protocol and compatibility risk where validation dominates coding time.

Practical expectation with strong AI pairing:

- Coding throughput can be much faster.
- Calendar still depends on how strictly you enforce verification gates.
- If you accept high risk and light validation, timeline compresses.
- If you want production-grade crypto assurance, validation time is the bottleneck.

---

## 6) Recommended Execution Strategy

- Start with Pass A + Pass B first (highest ROI, lowest protocol risk).
- Implement Pass C once envelope policy is stable.
- Defer Pass E (Double Ratchet) until A-D are stable and well-tested.

This gives a strong "good enough + scalable to best" path without locking you into a dead-end.

---

## 7) External Review Triage (Validated 2026-02-12)

Below are vetted findings from an additional review, filtered for usefulness.

### Accepted and Actionable

- Pairing code generation used non-cryptographic RNG and logged sensitive code data.
  - Verified in `lib/data/services/pairing_service.dart`.
  - **Fixed**:
    - `Random()` -> `Random.secure()`
    - redacted pairing-code value logs.
    - removed UI-layer PIN value logging in
      `lib/presentation/controllers/chat_pairing_dialog_controller.dart`.
- Timer hygiene remains a real operational concern.
  - Multiple `Timer.periodic(...)` usages still exist across mesh/monitoring services.
  - Not automatically a bug, but requires strict lifecycle ownership.
- Logging hygiene still needs hardening.
  - Runtime code no longer allows direct `print(...)` in `lib/**` via CI gate.
  - Ongoing hygiene still requires keeping logs secret-safe.
- Transport sender vs cryptographic sender separation is still a real protocol concern.
  - **Partially addressed**:
    - text message decrypt/verify now resolve declared sender identity (`senderId`/`originalSender`) instead of anchoring only on `fromNodeId`.
    - binary payload decrypt now resolves sender key through contact identity mapping before decrypt, with explicit fallback.
    - binary payload decrypt now fails closed if decryption does not succeed.
  - Remaining scope:
    - binary envelope itself does not yet carry a cryptographic sender field, so fully relay-safe sender attribution for multi-hop binary payloads remains pending protocol work.

### Rejected / Deprioritized

- Claim that `?optionalValue` map syntax is invalid Dart and blocks builds.
  - Rejected: this syntax is valid in current Dart and is lint-preferred in this repo
    (`use_null_aware_elements`).
  - Verified by successful analyze on:
    - `lib/domain/models/protocol_message.dart`
    - `lib/domain/services/mesh_networking_binary_helper.dart`

---

## 8) Pre-Threat-Model Pass Gate

Before running the dedicated adversarial threat-model review, complete this pass:

- Pass A foundation:
  - crypto header schema
  - deterministic decrypt routing by declared mode for v2
  - compatibility gate boundaries (legacy decrypt-only)

Status: ✅ Gate satisfied.

Rationale: threat-model review ROI is highest after envelope/mode/migration rules are explicit in code and docs.
