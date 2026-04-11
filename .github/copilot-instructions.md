# PakConnect Copilot Instructions

Read `AGENTS.md` first. It is the canonical repo contract for this repository.

This is a Flutter/Dart BLE mesh app. Do not treat it like a TypeScript, NestJS,
or generic CRUD web app.

Repo defaults:
- Preserve the existing layered architecture: `presentation`, `domain`, `core`,
  `data`.
- Stay within the current Riverpod 3.0 provider architecture.
- Do not introduce `provider`, `ChangeNotifier`, `go_router`, or alternate
  app-wide state/routing approaches unless the user explicitly asks for them.
- Use the `logging` package, not `print()`.
- Use `flutter test`, not `dart test`.
- For reviews, surface findings first with exact file/line references.
- For large or critical tasks, create or update `PLANS.md` before major edits.

Critical invariants to preserve:
- `Contact.publicKey` is immutable.
- Chat identity uses `persistentPublicKey ?? publicKey`.
- Noise encryption only starts after handshake establishment.
- Nonces are sequential.
- Message IDs are deterministic.
- Relay delivers locally before forwarding.
- Database changes preserve WAL, foreign keys, and migration tracking.
