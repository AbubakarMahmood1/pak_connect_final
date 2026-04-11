# GEMINI.md

`AGENTS.md` is the canonical source of truth for this repository.

Use this file as a lightweight Gemini-facing summary. Do not treat it as a
separate architecture document.

## Project Summary

PakConnect is a Flutter/Dart BLE mesh messaging app with:
- Noise Protocol end-to-end encryption
- SQLCipher-backed local persistence
- Riverpod 3.0 state management
- Strict layered architecture: `presentation`, `domain`, `core`, `data`

## Always Respect

- `Contact.publicKey` is immutable.
- `persistentPublicKey ?? publicKey` is the chat identity rule.
- No encryption before Noise handshake establishment.
- Nonces are sequential.
- Message IDs are deterministic.
- Relay delivers locally before forwarding.
- Database changes preserve WAL, FK behavior, and migration tracking.

## Repo Defaults

- Use Flutter/Dart-native solutions.
- Stay inside the current Riverpod provider architecture.
- Do not introduce alternate routing/state frameworks unless requested.
- Use `logging`, not `print()`.
- Use `flutter test`, not `dart test`.
- For larger or critical tasks, create/update `PLANS.md`.

## When More Detail Is Needed

Read the surviving repo docs on demand:
- `CONTRIBUTING.md` and `README.md` for repo/runtime context
- `ThreatModel.md`, `docs/security/security_overview.md`, and
  `docs/security/security_guarantees.md` for security-sensitive work
- `TESTING_STRATEGY.md` and `docs/testing/QUICK_START_TESTING.md` for
  verification flow
- `docs/srs/README.md` for requirements context
