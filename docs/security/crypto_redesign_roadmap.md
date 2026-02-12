# Crypto Redesign Roadmap (Validated)

**Date**: 2026-02-12  
**Status**: Drafted from validated repo state  
**Goal**: Evolve PakConnect toward a production-grade security architecture without blocking progressive delivery.

---

## 1) Validated Current State

This roadmap is based on current code paths, not generic advice:

- Multi-method crypto selection still exists in runtime policy:
  - `lib/core/services/security_manager.dart`
  - Active method set includes `noise`, `ecdh`, `pairing`, and legacy/global fallback paths.
- Noise sessions are implemented and hardened (nonce locking, replay checks, rekey thresholds), but this is not a Double Ratchet:
  - `lib/core/security/noise/noise_session.dart`
  - `lib/core/security/noise/noise_session_manager.dart`
  - `lib/core/security/noise/noise_encryption_service.dart`
- Outbound send is mostly fail-closed for legacy/global encrypt path, but decrypt compatibility paths still include legacy/global handling:
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
  - `print(...)` removed from `lib/**` runtime code (doc comments excluded).
- Runtime hygiene gates added to CI:
  - no non-comment `print(...)` in `lib/**`.
  - `Timer.periodic(...)` count regression gate capped at current baseline.
- Pass B migration scaffold added:
  - outbound v2 send path can now fail-closed on legacy modes using
    `PAKCONNECT_ALLOW_LEGACY_V2_SEND=false`.
  - default remains compatibility-on (`true`) for progressive rollout.

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

**Status**: In progress (`2026-02-12`).

Implemented now:
- strict policy gate exists for outbound v2 legacy mode emission.

Remaining:
- make strict mode default in controlled stages.
- add sealed/offline lane so strict mode does not block non-live delivery use cases.

### Pass C (35-55%): Offline Async Prekey Lane

- Implement one-shot recipient decryptable payload lane for offline/store-forward.
- Keep sender auth explicit and verifiable in the envelope.

**Exit criteria**

- Offline recipient can decrypt without prior interactive handshake.
- Relay path remains opaque to plaintext.
- Replay controls and message ID semantics remain deterministic.

### Pass D (55-75%): Live Session Lifecycle Hardening

- Tighten session ownership/rekey orchestration.
- Enforce strict stale-event suppression and downgrade policy.
- Strengthen failure semantics (no silent weaker-mode drift).

**Exit criteria**

- Session transitions deterministic under reconnect/drop/out-of-order conditions.
- Rekey behavior tested in long-running session simulations.

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
- Timer hygiene remains a real operational concern.
  - Multiple `Timer.periodic(...)` usages still exist across mesh/monitoring services.
  - Not automatically a bug, but requires strict lifecycle ownership.
- Logging hygiene still needs hardening.
  - `print(...)` calls remain in `lib/**` (non-test code) and should be removed or gated.
- Transport sender vs cryptographic sender separation is still a real protocol concern.
  - **Partially addressed**:
    - text message decrypt/verify now resolve declared sender identity (`senderId`/`originalSender`) instead of anchoring only on `fromNodeId`.
    - binary payload decrypt now resolves sender key through contact identity mapping before decrypt, with explicit fallback.
  - Remaining scope:
    - binary envelope itself does not yet carry a cryptographic sender field, so fully relay-safe sender attribution for multi-hop binary payloads remains pending protocol work.

### Rejected / Deprioritized

- Claim that `?optionalValue` map syntax is invalid Dart and blocks builds.
  - Not valid for this repo/toolchain.
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
