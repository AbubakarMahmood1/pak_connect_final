---
applyTo: "lib/core/security/**/*.dart,lib/core/bluetooth/**/*.dart,lib/core/messaging/**/*.dart,lib/data/database/**/*.dart"
---

You are editing a critical PakConnect subsystem.

Before major edits:
- Read `AGENTS.md`.
- Create or update `PLANS.md` unless the change is obviously tiny.

Preserve these invariants:
- No encryption before Noise handshake establishment.
- Nonces remain strictly sequential.
- Handshake phases remain ordered and Phase 1.5 blocks Phase 2.
- Originating message IDs remain opaque and stable through queue/relay
  handling; the receive helper derives a fallback only when an inbound frame
  lacks an ID.
- Relay still delivers locally before forwarding.
- Database migrations remain transactional and preserve WAL plus FK behavior.

Verification bar:
- Prefer `flutter analyze`.
- Run targeted `flutter test` for the touched subsystem.
- Call out any skipped verification explicitly.
