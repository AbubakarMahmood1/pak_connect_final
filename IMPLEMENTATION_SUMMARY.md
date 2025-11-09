# Implementation Summary: Spy Mode + Identity Resolution

**Date**: 2025-10-20

---

## What Was Implemented

### Phase 1: Identity Resolution for Noise Sessions ✅ COMPLETE

**Problem**: Noise sessions keyed by ephemeral IDs, but paired contacts use persistent keys.

**Solution**: Automatic identity resolution in Noise session manager.

**Files Modified**:
1. `lib/core/security/noise/noise_session_manager.dart`
   - Added `_persistentToEphemeral` mapping
   - Added `resolveSessionID()` method
   - Updated `encrypt()` and `decrypt()` to resolve automatically

2. `lib/core/security/noise/noise_encryption_service.dart`
   - Exposed `registerIdentityMapping()` method
   - Exposed `unregisterIdentityMapping()` method

3. `lib/core/services/security_manager.dart`
   - Added static `registerIdentityMapping()` wrapper
   - Added static `unregisterIdentityMapping()` wrapper

4. `lib/data/services/ble_state_manager.dart`
   - Calls `SecurityManager.registerIdentityMapping()` after MEDIUM upgrade
   - Updated `getRecipientId()` to return persistent key if paired

5. `lib/data/services/ble_service.dart`
   - Simplified `_processMessage()` decryption logic
   - Now uses persistent keys when available

**Result**: Encryption/decryption transparently works with persistent OR ephemeral keys.

---

### Phase 2: Spy Mode Foundation ✅ COMPLETE

**Problem**: Need anonymous chat mode for privacy/whistleblowing.

**Solution**: Hint broadcast toggle + identity resolution based on mode.

**Files Modified**:
1. `lib/data/repositories/user_preferences.dart`
   - Added `_hintBroadcastKey` constant
   - Added `getHintBroadcastEnabled()` method (default: true)
   - Added `setHintBroadcastEnabled()` method

2. `lib/data/services/ble_message_handler.dart`
   - Added `_resolveMessageIdentities()` method
   - Added `_MessageIdentities` model class
   - Updated `sendMessage()` to call identity resolution
   - Added imports for `UserPreferences` and `EphemeralKeyManager`

**Logic**:
```dart
if (hintsOFF && noiseSessionExists) {
  // Spy mode
  originalSender = myEphemeralID;
  intendedRecipient = theirEphemeralID;
} else {
  // Normal mode
  originalSender = myPersistentKey;
  intendedRecipient = theirPersistentKey;
}
```

**Result**: Message identities automatically adapt to spy mode status.

---

## What Still Needs Implementation

### Phase 3: Use Resolved Identities in Protocol Messages 🔲 PENDING

**File**: `lib/data/services/ble_message_handler.dart`

**Task**: Update protocol message creation to use `finalRecipientId` and `finalSenderId` from `_resolveMessageIdentities()`.

**Current Code** (line ~228):
```dart
final legacyPayload = {
  ...protocolMessage.payload,
  'encryptionMethod': encryptionMethod,
  'intendedRecipient': originalIntendedRecipient ?? contactPublicKey,  // ❌ WRONG
};
```

**Should Be**:
```dart
final legacyPayload = {
  ...protocolMessage.payload,
  'encryptionMethod': encryptionMethod,
  'intendedRecipient': finalRecipientId,     // ✅ From identity resolution
  'originalSender': finalSenderIf,           // ✅ From identity resolution
};
```

---

### Phase 4: Message Reception - "Is This For Me?" 🔲 PENDING

**File**: `lib/data/services/ble_service.dart`

**Task**: Check message against ALL possible identities.

**Add Method**:
```dart
Future<bool> _isMessageForMe(String intendedRecipient) async {
  final userPrefs = UserPreferences();
  final myPersistentKey = await userPrefs.getPublicKey();
  final myEphemeralID = EphemeralKeyManager.instance.currentEphemeralId;
  final myHintID = /* TODO: get from hint system */;

  // Check all identities
  return intendedRecipient == myPersistentKey ||   // Friend mode
         intendedRecipient == myEphemeralID ||     // Spy mode
         intendedRecipient == myHintID;            // Relay routing
}
```

**Use in `_processMessage()`**:
```dart
if (!await _isMessageForMe(intendedRecipient)) {
  _logger.info('Message not for me, discarding');
  return;
}
```

---

### Phase 5: Spy Mode Detection & Reveal Prompt 🔲 PENDING

**File**: `lib/data/services/ble_state_manager.dart`

**Task**: After Noise handshake, detect if peer is a friend and prompt for reveal.

**Add Callback**:
```dart
typedef SpyModeDetectedCallback = void Function(SpyModeInfo info);

SpyModeDetectedCallback? onSpyModeDetected;

class SpyModeInfo {
  final String contactName;
  final String ephemeralID;
  final String? persistentKey;

  SpyModeInfo({
    required this.contactName,
    required this.ephemeralID,
    this.persistentKey,
  });
}
```

**Add to Handshake Complete**:
```dart
Future<void> handlePersistentKeyExchange(String theirPersistentKey) async {
  // ... existing code ...

  // Check if in spy mode
  final userPrefs = UserPreferences();
  final hintsEnabled = await userPrefs.getHintBroadcastEnabled();

  if (!hintsEnabled) {
    // Spy mode detected
    final contact = await _contactRepository.getContact(theirPersistentKey);
    if (contact != null) {
      onSpyModeDetected?.call(SpyModeInfo(
        contactName: contact.displayName,
        ephemeralID: _theirEphemeralId!,
        persistentKey: theirPersistentKey,
      ));
    }
  }
}
```

---

### Phase 6: FRIEND_REVEAL Protocol 🔲 PENDING

**File**: `lib/domain/entities/protocol_message.dart`

**Task**: Add new protocol message type for identity reveal.

**Add Enum Value**:
```dart
enum ProtocolMessageType {
  // ... existing types ...
  friendReveal,  // NEW
}
```

**File**: `lib/data/services/ble_state_manager.dart`

**Add Method**:
```dart
Future<void> revealIdentityToFriend() async {
  final userPrefs = UserPreferences();
  final myPersistentKey = await userPrefs.getPublicKey();

  // Generate proof of ownership
  final proof = await _generateProofOfOwnership(myPersistentKey);

  // Create reveal message
  final revealMessage = ProtocolMessage(
    type: ProtocolMessageType.friendReveal,
    payload: {
      'myPersistentKey': myPersistentKey,
      'proof': proof,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    },
    timestamp: DateTime.now().millisecondsSinceEpoch,
  );

  // Send via BLE
  await _sendProtocolMessage(revealMessage);
}
```

**Add Handler**:
```dart
Future<void> _handleFriendReveal(Map<String, dynamic> payload) async {
  final theirPersistentKey = payload['myPersistentKey'] as String;
  final proof = payload['proof'] as String;
  final timestamp = payload['timestamp'] as int;

  // Verify timestamp (reject if > 5 minutes old)
  if (DateTime.now().millisecondsSinceEpoch - timestamp > 300000) {
    _logger.warning('FRIEND_REVEAL rejected: Timestamp too old');
    return;
  }

  // Verify proof
  if (!await _verifyProofOfOwnership(theirPersistentKey, proof)) {
    _logger.warning('FRIEND_REVEAL rejected: Invalid proof');
    return;
  }

  // Check if in contacts
  final contact = await _contactRepository.getContact(theirPersistentKey);
  if (contact != null) {
    _logger.info('🕵️ Identity revealed: ${contact.displayName}');

    // Register mapping
    SecurityManager.registerIdentityMapping(
      persistentPublicKey: theirPersistentKey,
      ephemeralID: _theirEphemeralId!,
    );

    // Update UI
    onIdentityRevealed?.call(contact.displayName);
  }
}
```

---

### Phase 7: Encryption Priority Fix 🔲 PENDING

**Problem**: Current cascade tries Noise before Pairing for MEDIUM security.

**File**: `lib/core/services/security_manager.dart`

**Current** (lines 204-213):
```dart
case SecurityLevel.medium:
  // ❌ WRONG ORDER: Noise first
  if (_noiseService != null && _noiseService!.hasEstablishedSession(sessionLookupKey)) {
    return EncryptionMethod.noise(sessionLookupKey);
  }
  // Pairing is fallback
  if (_verifyPairingKey(publicKey)) {
    return EncryptionMethod.pairing(publicKey);
  }
```

**Should Be**:
```dart
case SecurityLevel.medium:
  // ✅ CORRECT ORDER: Pairing first
  if (_verifyPairingKey(publicKey)) {
    return EncryptionMethod.pairing(publicKey);
  }
  // Noise is fallback (for spy mode)
  if (_noiseService != null && _noiseService!.hasEstablishedSession(sessionLookupKey)) {
    return EncryptionMethod.noise(sessionLookupKey);
  }
```

---

### Phase 8: Chat Separation 🔲 PENDING

**Database Schema**:
```sql
ALTER TABLE chats ADD COLUMN is_spy_mode INTEGER DEFAULT 0;
ALTER TABLE chats ADD COLUMN revealed_at INTEGER;
CREATE INDEX idx_chats_spy_mode ON chats(is_spy_mode);
```

**Chat Creation Logic**:
```dart
Future<void> _createChatForMessage({
  required String senderKey,
  required String recipientKey,
  required bool isSpyMode,
}) async {
  final chatId = isSpyMode
      ? 'spy_${senderKey}_${recipientKey}'  // Separate spy chat
      : 'friend_${senderKey}';                // Normal friend chat

  await _chatRepository.createChat(
    chatId: chatId,
    contactPublicKey: senderKey,
    isSpyMode: isSpyMode,
  );
}
```

---

### Phase 9: UI Components 🔲 PENDING

**1. Settings Toggle** (`lib/presentation/screens/settings_screen.dart`):
```dart
SwitchListTile(
  title: Text('Broadcast Hints'),
  subtitle: Text(
    hintsEnabled
      ? 'Friends know when you\'re online'
      : '🕵️ Spy mode: Chat anonymously'
  ),
  value: hintsEnabled,
  onChanged: (value) async {
    await userPrefs.setHintBroadcastEnabled(value);
    setState(() {});
  },
)
```

**2. Spy Mode Reveal Dialog** (`lib/presentation/dialogs/spy_mode_dialog.dart`):
```dart
class SpyModeRevealDialog extends StatelessWidget {
  final SpyModeInfo info;

  Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('🕵️ Anonymous Session'),
        content: Text(
          'You\'re chatting with ${info.contactName} anonymously.\n\n'
          'They don\'t know it\'s you.'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Stay Anonymous'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Reveal Identity'),
          ),
        ],
      ),
    );
  }
}
```

**3. Chat List Badge** (`lib/presentation/screens/chat_list_screen.dart`):
```dart
if (chat.isSpyMode) {
  ListTile(
    leading: Badge(
      label: Text('🕵️'),
      child: CircleAvatar(),
    ),
    title: Text(chat.displayName),
    subtitle: Text('Anonymous chat'),
  );
}
```

---

## Testing Plan

### Unit Tests

1. **Identity Resolution** (`test/identity_resolution_test.dart`):
   - Hints ON → returns persistent keys
   - Hints OFF + Noise session → returns ephemeral keys
   - Hints OFF + no session → returns persistent keys

2. **Noise Session Mapping** (`test/noise_session_mapping_test.dart`):
   - Register mapping → resolve works
   - Encrypt with persistent → decrypts correctly
   - Unregister mapping → falls back to direct lookup

3. **Message Identity Check** (`test/message_identity_test.dart`):
   - `_isMessageForMe()` checks all three identities
   - Returns true for persistent, ephemeral, and hint IDs
   - Returns false for unknown IDs

### Integration Tests

1. **Spy Mode Flow** (`test/spy_mode_flow_test.dart`):
   - Alice enables spy mode
   - Alice connects to Bob
   - Messages use ephemeral IDs
   - Bob sees "Anonymous User"

2. **Identity Reveal** (`test/identity_reveal_test.dart`):
   - Alice reveals to Bob
   - Bob receives FRIEND_REVEAL
   - Bob updates UI to show "Alice"
   - Future messages use persistent keys

3. **Chat Separation** (`test/chat_separation_test.dart`):
   - Alice chats with Bob normally
   - Alice enables spy mode, reconnects
   - Two separate chats exist
   - Messages don't cross-contaminate

---

## Current Status

✅ **COMPLETED**:
- Identity resolution in Noise session manager
- Hint broadcast setting
- Spy mode identity resolution logic
- Documentation (this file + SPY_MODE_IMPLEMENTATION.md)

🔲 **PENDING**:
- Use resolved identities in protocol messages
- "Is this for me?" check in message reception
- Spy mode detection + reveal prompt
- FRIEND_REVEAL protocol
- Encryption priority fix
- Chat separation (database + logic)
- UI components

---

## Next Steps

**Priority 1**: Fix encryption priority (Pairing before Noise for MEDIUM)
**Priority 2**: Use resolved identities in protocol messages
**Priority 3**: Implement "is this for me?" check
**Priority 4**: Spy mode detection + UI prompt
**Priority 5**: FRIEND_REVEAL protocol
**Priority 6**: Chat separation
**Priority 7**: Settings UI
