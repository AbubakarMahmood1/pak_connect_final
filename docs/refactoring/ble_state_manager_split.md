# BLEStateManager Split Outline (Phase 4)

Context: `lib/data/services/ble_state_manager.dart` currently mixes identity/session state, pairing/contact workflows, and peripheral/role flags (~2.3k lines). This note captures the target seams before moving logic.

## Proposed Modules
- **IdentitySessionState** (`core/bluetooth/identity_session_state.dart`):
  - Session identity tracking: `_currentSessionId`, `_theirEphemeralId`, `_theirPersistentKey`, `_ephemeralToPersistent`
  - Helper methods: `setTheirEphemeralId`, `getRecipientId`, `isPaired`, `getIdType`, `recoverIdentityFromStorage`, `_truncateId`
  - Spy-mode hooks: `onSpyModeDetected`, `onIdentityRevealed`, `revealIdentityToFriend`, `_detectSpyMode`
  - Persistence helpers: `getIdentityWithFallback`, `clearSessionState`, `clearOtherUserName`

- **PairingAndContacts** (`data/services/pairing_contact_controller.dart`):
  - Pairing lifecycle: pairing request/accept/cancel, `_currentPairing`, `_pairingTimeout`, verification code generation
  - Persistent key exchange and chat migration: `_exchangePersistentKeys`, `handlePersistentKeyExchange`, `_triggerChatMigration`
  - Contact request flow and mutual consent: `sendContactRequest`, `handleContactRequest`, accept/reject, `_pendingOutgoingRequests`
  - Security level sync/reset: `confirmSecurityUpgrade`, `resetContactSecurity`, `_initializeCryptoForLevel`
  - Contact relationship sync: `_sendContactStatusIfChanged`, `_performBilateralContactSync`, `_retryContactStatusExchange`, `_isContactStateAsymmetric`

- **PeripheralRoleState** (`core/bluetooth/role_state_tracker.dart`):
  - Peripheral/central role flags: `_isPeripheralMode`, `setPeripheralMode`, role-aware callbacks
  - Navigation-safe clears: `preserveContactRelationship`, `clearSessionState(preservePersistentId: true)`
  - Device discovery callbacks and RSSI/metrics placeholders

- **Facade/Adapter** (`BLEStateManager` trimmed):
  - Keep callbacks surface and DI wiring intact for BLEServiceFacade
  - Delegate to the new components; maintain public getters/setters
  - Thin coordination for tests until consumers migrate

## Safety Checks
- Preserve critical invariants from AGENTS.md:
  - Contact.publicKey immutable; chat ID resolution uses `persistentPublicKey ?? publicKey`
  - Noise handshake stays sequential; no encryption before establishment
  - Nonce sequencing untouched; MTU negotiation remains Phase 0
  - Relay/local delivery ordering unaffected
- Avoid touching Noise or handshake phases during split; focus on structural extraction only.

## Migration Notes
- Introduce components incrementally; keep old method signatures on the facade to avoid cascading changes.
- After extraction, wire the new classes into existing DI (BLEServiceFacade, connection manager) and add adapter unit tests where feasible.
