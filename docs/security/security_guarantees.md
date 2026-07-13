# Security Boundaries (Milestone 0)

This document separates implemented code boundaries from verified runtime
evidence. Device-only claims require the evidence recorded in
`docs/testing/DEVICE_VALIDATION_STATUS.md`.

## Implemented and Automated Boundaries

1. Mobile database initialization path
- On Android/iOS, `DatabaseHelper` opens SQLCipher with a password from secure storage (`DatabaseEncryption.getOrCreateEncryptionKey()`).
- If secure storage key retrieval fails on mobile, initialization fails closed.
- The key is a randomly generated 256-bit value stored in platform secure storage; it is not derived from an application login passphrase.
- Physical-device proof that the resulting database file is unreadable without
  that credential remains pending; the code path alone is not at-rest evidence.

2. Fail-closed message encryption for outbound transport
- Outbound text and binary send paths call `SecurityManager` encryption first.
- If encryption is unavailable/fails, send aborts and transport write is not executed.

3. No hardcoded legacy/global passphrase in runtime code
- Legacy/global compatibility lanes have been removed from active runtime code.

4. No timestamp-based PRNG seeding for cryptographic operations
- Cryptographic seeding uses `Random.secure()` rather than timestamp-derived seeds.

5. Platform policy blockers covered
- iOS `Info.plist` includes Bluetooth usage description keys.
- Android release signing is configured via `android/key.properties` or `ANDROID_*` env vars; release builds fail if signing values are missing.

## Explicit Limits

1. Desktop/test DBs
- Desktop/test DB factories may run without SQLCipher and are not mobile
  encryption-at-rest evidence.

2. Removed compatibility lanes
- Legacy archive field decrypt and legacy global payload decrypt are no longer supported.
- Older data written in those deprecated formats will not be decoded by current runtime code.

## Verification Artifacts

1. Unit fail-closed transport test
- `test/data/services/ble_write_adapter_test.dart`
- Asserts no BLE bytes are written when encryption fails.

2. Pending device integration encryption proof target
- `integration_test/security/database_encryption_device_test.dart`
- Intended to verify that the DB file is not plaintext SQLite and cannot be
  queried without its credential. Its presence is not proof that it has run on
  a physical device; consult `DEVICE_VALIDATION_STATUS.md` for execution state.
