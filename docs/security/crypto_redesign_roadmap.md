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

### Pass B (15-35%): New-Send Path Simplification

- New outbound send path uses only:
  - `noise_session` when session exists.
  - `async_prekey` when no live session exists.
- Remove new-send dependence on `global` and ad-hoc legacy fallback selection.

**Exit criteria**

- No new outbound payload is produced with legacy/global mode.
- Fallback logic only applies to old incoming messages.

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

