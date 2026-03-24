# Threat-Model Review Packet (After Pass B + Pass C Scaffold)

Use this packet when asking an `o`-series model for adversarial review with limited context.

## Goal

Validate envelope/mode policy and Pass C sealed-lane scaffold before full wiring.

## Batch 1 (Required, highest ROI)

1. `docs/security/crypto_redesign_roadmap.md`
2. `lib/domain/models/crypto_header.dart`
3. `lib/domain/models/protocol_message.dart`
4. `lib/domain/interfaces/i_security_service.dart`
5. `lib/core/services/security_manager.dart`
6. `lib/data/services/protocol_message_handler.dart`
7. `lib/data/services/inbound_text_processor.dart`
8. `lib/data/services/outbound_message_sender.dart`
9. `lib/core/security/sealed/sealed_encryption_service.dart`
10. `test/core/security/sealed/sealed_encryption_service_test.dart`
11. `test/data/services/protocol_message_handler_test.dart`
12. `test/data/services/ble_write_adapter_test.dart`

## Batch 2 (Follow-up, if token budget allows)

1. `lib/data/services/ble_message_handler_facade.dart` (binary payload decrypt path)
2. `lib/data/services/pairing_service.dart` (pairing hardening verification)
3. `scripts/runtime_hygiene_audit.ps1`
4. `.github/workflows/flutter_coverage.yml`

## Review Questions to Ask

1. Does v2 decrypt routing fail closed by declared crypto mode, with no fallback guessing?
2. Are there any downgrade paths where v2 can accidentally use legacy decrypt behavior?
3. Are sender identity and transport identity cleanly separated for decrypt and signature checks?
4. What concrete attack scenarios still remain in current Pass A code?
5. What is the minimum safe spec for Pass B (noise/sealed send policy) to avoid regressions?
6. Are removed legacy v2 transport modes rejected consistently on both outbound and inbound paths, with no residual fallback behavior?
7. Does `sealed_encryption_service.dart` have any construction-level mistakes (KDF, nonce handling, key erasure, AAD semantics)?
8. What is the minimum safe envelope spec for wiring sealed mode (`kid`, `epk`, `nonce`, sender binding) without creating downgrade or replay gaps?
9. Does the automatic sealed fallback for removed legacy transport attempts create any downgrade confusion or ambiguous sender/recipient binding?
10. Does the new `decryptSealedMessage(...)` API/usage bind the same AAD context as sender-side sealing, and what edge cases remain?
