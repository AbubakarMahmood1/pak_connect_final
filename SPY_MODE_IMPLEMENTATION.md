# Spy Mode Implementation Guide

**Date**: 2025-10-20
**Feature**: Anonymous Sessions Between Friends

---

## Overview

PakConnect supports **TWO distinct chat modes** between the same pair of users:

1. **Friend Mode** - Persistent identity, relay routing works
2. **Spy Mode** - Anonymous ephemeral identity, direct-only connection

---

## Core Design Principles

### Identity Selection Logic

```dart
// Determine sender identity
if (myHintsOFF && noiseSessionExists) {
  originalSender = myEphemeralID;      // Anonymous
} else {
  originalSender = myPersistentKey;    // Identifiable
}

// Determine recipient identity
if (myHintsOFF && noiseSessionExists) {
  intendedRecipient = theirEphemeralID;     // Anonymous (assumes they're online)
} else {
  intendedRecipient = theirPersistentKey;   // Persistent (works offline)
}
```

### Encryption Priority

```
1. ECDH/Pairing (if contact exists AND hints ON)
2. Noise session (if exists - used in spy mode OR as fallback)
3. Global encryption (last resort)
```

---

## User Experience Flows

### Scenario 1: Normal Friend Chat (Hints ON)

```
Alice (hints ON) → Bob (hints ON)

1. Both broadcast hints (topology visible)
2. Noise handshake completes
3. Check contacts: Bob is Alice's friend
4. Upgrade to persistent identity automatically
5. Messages use ECDH/Pairing encryption
6. intendedRecipient = Bob's persistent key
7. Single chat: "Bob"
```

### Scenario 2: Spy Mode (Hints OFF)

```
Alice (hints OFF) → Bob (hints ON)

1. Alice doesn't broadcast hint (topology hidden)
2. Noise handshake completes (anonymous)
3. Alice checks: Bob is her friend, but she's in spy mode
4. Alice keeps using ephemeral IDs
5. Messages use Noise encryption
6. intendedRecipient = Bob's ephemeral ID
7. Bob sees: "Anonymous User" (new chat)
8. Alice sees: Chat tagged with Bob's ephemeral ID

Result: Two separate chats
- Bob's normal chat: "Alice" (from when hints were ON)
- Bob's spy chat: "Anonymous User" (from Alice with hints OFF)
```

### Scenario 3: Mutual Spy Mode

```
Alice (hints OFF) → Bob (hints OFF)

1. Neither broadcasts hints
2. Noise handshake completes
3. Both check contacts: recognize each other
4. Both stay in spy mode (respecting privacy choice)
5. Messages use Noise + ephemeral IDs
6. Both see: "Anonymous User"
7. Neither can prove identity without revealing
```

### Scenario 4: Spy Mode Reveal (User Choice)

```
Alice (hints OFF, spy mode) → Bob

1. Alice connects anonymously to Bob
2. PakConnect detects: Bob is in Alice's contacts
3. Show prompt: "Reveal identity to Bob?"
4. If YES:
   - Send FRIEND_REVEAL message
   - Bob updates: "Oh, it's Alice!"
   - Merge chats OR keep separate (user choice)
5. If NO:
   - Continue in spy mode
   - Alice can reveal anytime later
```

---

## Implementation Components

### 1. Hint Broadcast Setting

**File**: `lib/data/repositories/user_preferences.dart`

```dart
// Get hint status
Future<bool> getHintBroadcastEnabled() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('hint_broadcast_enabled') ?? true;
}

// Set hint status (enables/disables spy mode)
Future<void> setHintBroadcastEnabled(bool enabled) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('hint_broadcast_enabled', enabled);
}
```

### 2. Identity Resolution in Message Sending

**File**: `lib/data/services/ble_message_handler.dart` (to be modified)

```dart
Future<MessageIdentities> _resolveMessageIdentities({
  required String recipientContactKey,
  required ContactRepository repo,
}) async {
  final userPrefs = UserPreferences();
  final hintsEnabled = await userPrefs.getHintBroadcastEnabled();

  // Get my identities
  final myPersistentKey = await userPrefs.getPublicKey();
  final myEphemeralID = EphemeralKeyManager.instance.currentEphemeralId;

  // Get recipient identities
  final contact = await repo.getContact(recipientContactKey);
  final noiseSessionExists = SecurityManager.noiseService
      ?.hasEstablishedSession(contact?.currentEphemeralId ?? '');

  // RULE 1: Sender identity
  String originalSender;
  if (!hintsEnabled && noiseSessionExists == true) {
    originalSender = myEphemeralID;  // Spy mode
  } else {
    originalSender = myPersistentKey;  // Normal mode
  }

  // RULE 2: Recipient identity
  String intendedRecipient;
  if (!hintsEnabled && noiseSessionExists == true && contact?.currentEphemeralId != null) {
    intendedRecipient = contact!.currentEphemeralId!;  // Spy mode (ephemeral)
  } else if (contact?.persistentPublicKey != null) {
    intendedRecipient = contact!.persistentPublicKey!;  // Normal mode (persistent)
  } else {
    intendedRecipient = contact?.publicKey ?? recipientContactKey;  // Fallback
  }

  return MessageIdentities(
    originalSender: originalSender,
    intendedRecipient: intendedRecipient,
    isSpyMode: !hintsEnabled && noiseSessionExists == true,
  );
}

class MessageIdentities {
  final String originalSender;
  final String intendedRecipient;
  final bool isSpyMode;

  MessageIdentities({
    required this.originalSender,
    required this.intendedRecipient,
    required this.isSpyMode,
  });
}
```

### 3. Message Reception (Checking "Is this for me?")

**File**: `lib/data/services/ble_service.dart` (to be modified)

```dart
Future<bool> _isMessageForMe(String intendedRecipient) async {
  final userPrefs = UserPreferences();
  final myPersistentKey = await userPrefs.getPublicKey();
  final myEphemeralID = EphemeralKeyManager.instance.currentEphemeralId;
  final myHintID = /* get from hint system */;

  // Check all possible identities
  return intendedRecipient == myPersistentKey ||   // Normal friend mode
         intendedRecipient == myEphemeralID ||     // Spy mode
         intendedRecipient == myHintID;            // Relay routing
}
```

### 4. Spy Mode Detection & Prompt

**File**: `lib/data/services/ble_state_manager.dart` (to be modified)

```dart
Future<void> _onNoiseHandshakeComplete(String theirEphemeralID) async {
  // Check if this peer is actually a contact
  final contact = await _contactRepository.getContactByAnyId(theirEphemeralID);

  if (contact != null) {
    // Friend detected!
    final userPrefs = UserPreferences();
    final hintsEnabled = await userPrefs.getHintBroadcastEnabled();

    if (!hintsEnabled) {
      // Spy mode detected - show prompt
      _logger.info('🕵️ Spy mode: Connected to friend ${contact.displayName} anonymously');

      // Trigger UI callback to show reveal prompt
      onSpyModeDetected?.call(SpyModeInfo(
        contactName: contact.displayName,
        ephemeralID: theirEphemeralID,
        persistentKey: contact.persistentPublicKey,
      ));
    } else {
      // Normal mode - auto-reveal
      await _revealIdentityToFriend(contact);
    }
  }
}

Future<void> _revealIdentityToFriend(Contact contact) async {
  final userPrefs = UserPreferences();
  final myPersistentKey = await userPrefs.getPublicKey();

  // Send FRIEND_REVEAL protocol message
  final revealMessage = ProtocolMessage(
    type: ProtocolMessageType.friendReveal,
    payload: {
      'myPersistentKey': myPersistentKey,
      'proof': await _generateProofOfOwnership(myPersistentKey),
    },
    timestamp: DateTime.now().millisecondsSinceEpoch,
  );

  // Send via BLE
  await _sendProtocolMessage(revealMessage);

  // Register identity mapping locally
  SecurityManager.registerIdentityMapping(
    persistentPublicKey: contact.persistentPublicKey ?? contact.publicKey,
    ephemeralID: contact.currentEphemeralId ?? contact.publicKey,
  );
}
```

### 5. FRIEND_REVEAL Protocol

**File**: `lib/domain/entities/protocol_message.dart` (to be modified)

```dart
enum ProtocolMessageType {
  // ... existing types
  friendReveal,  // NEW: Reveal persistent identity in spy mode
}

// Handler for FRIEND_REVEAL
Future<void> _handleFriendReveal(Map<String, dynamic> payload) async {
  final theirPersistentKey = payload['myPersistentKey'] as String;
  final proof = payload['proof'] as String;

  // Verify proof of ownership
  if (!await _verifyProofOfOwnership(theirPersistentKey, proof)) {
    _logger.warning('🕵️ FRIEND_REVEAL failed: Invalid proof');
    return;
  }

  // Check if this persistent key is in our contacts
  final contact = await _contactRepository.getContact(theirPersistentKey);

  if (contact != null) {
    _logger.info('🕵️ FRIEND_REVEAL: Anonymous user is actually ${contact.displayName}!');

    // Update ephemeral → persistent mapping
    SecurityManager.registerIdentityMapping(
      persistentPublicKey: theirPersistentKey,
      ephemeralID: _stateManager.theirEphemeralId!,
    );

    // Update contact's current ephemeral ID
    await _contactRepository.updateContactEphemeralId(
      theirPersistentKey,
      _stateManager.theirEphemeralId!,
    );

    // Notify UI: "Anonymous User" → "Alice"
    onIdentityRevealed?.call(contact.displayName);
  }
}
```

---

## Chat Separation Strategy

### Database Schema Update

```sql
-- Add spy mode flag to chats
ALTER TABLE chats ADD COLUMN is_spy_mode INTEGER DEFAULT 0;
ALTER TABLE chats ADD COLUMN revealed_at INTEGER;  -- Timestamp of identity reveal

-- Index for filtering
CREATE INDEX idx_chats_spy_mode ON chats(is_spy_mode);
```

### Chat List Display

```dart
// Show both chats for same person
Chats for Alice:

1. "Alice" (persistent)
   - Last message: "See you tomorrow!"
   - is_spy_mode: 0

2. "Anonymous (might be Alice)" (ephemeral)
   - Last message: "..."
   - is_spy_mode: 1
   - Show badge: "🕵️ Anonymous"
```

---

## Security Considerations

### 1. Preventing Identity Leakage

**Problem**: Metadata analysis could reveal spy mode users

**Solution**:
- Message timing randomization
- Dummy traffic when idle
- Consistent message sizes (padding)

### 2. Proof of Ownership

When revealing identity, prove you own the persistent key:

```dart
// Generate proof
String proof = signWithPersistentKey(
  message: theirEphemeralID + timestamp,
  privateKey: myPersistentPrivateKey,
);

// Verify proof
bool valid = verifySignature(
  message: myEphemeralID + timestamp,
  signature: proof,
  publicKey: theirPersistentKey,
);
```

### 3. Replay Attack Protection

FRIEND_REVEAL messages must include:
- Timestamp (reject if > 5 minutes old)
- Nonce (prevent replay)
- Challenge-response (bind to current session)

---

## UI Components (To Be Created)

### 1. Settings Toggle

```dart
// Settings screen
SwitchListTile(
  title: Text('Broadcast Hints (Spy Mode)'),
  subtitle: Text(
    hintsEnabled
      ? 'Friends can see when you\'re online'
      : '🕵️ Spy mode: Chat anonymously with friends'
  ),
  value: hintsEnabled,
  onChanged: (value) async {
    await userPrefs.setHintBroadcastEnabled(value);
  },
)
```

### 2. Spy Mode Reveal Dialog

```dart
Future<void> showSpyModeRevealDialog(SpyModeInfo info) async {
  return showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Row(
        children: [
          Text('🕵️ Anonymous Session'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('You\'re chatting with ${info.contactName} anonymously.'),
          SizedBox(height: 16),
          Text('They don\'t know it\'s you.'),
        ],
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
```

### 3. Chat Badge

```dart
// Show spy mode indicator in chat list
if (chat.isSpyMode) {
  Badge(
    label: Text('🕵️'),
    child: ListTile(
      title: Text(chat.displayName),
      subtitle: Text('Anonymous chat'),
    ),
  );
}
```

---

## Testing Scenarios

### Test 1: Spy Mode Initiation
- Alice enables spy mode (hints OFF)
- Alice connects to Bob (who has hints ON)
- Verify: Bob sees "Anonymous User"
- Verify: Messages use ephemeral IDs

### Test 2: Identity Reveal
- Alice in spy mode with Bob
- Alice chooses "Reveal Identity"
- Verify: Bob receives FRIEND_REVEAL
- Verify: Bob's UI updates: "Anonymous User" → "Alice"

### Test 3: Mutual Spy Mode
- Both Alice and Bob have hints OFF
- They connect and chat
- Verify: Both see "Anonymous User"
- Verify: Neither can reveal without enabling hints

### Test 4: Chat Separation
- Alice chats with Bob normally (hints ON)
- Alice enables spy mode and reconnects to Bob
- Verify: Two separate chats exist
- Verify: Messages don't cross-contaminate

### Test 5: Encryption Fallback
- Alice (spy mode) with Bob
- Noise session expires
- Verify: Falls back to persistent key encryption
- Verify: Bob still receives messages

---

## Migration Path

### Phase 1: Hint Broadcast Setting (DONE)
- Added `getHintBroadcastEnabled()` / `setHintBroadcastEnabled()`

### Phase 2: Identity Resolution (CURRENT)
- Modify `_resolveMessageIdentities()` in ble_message_handler.dart
- Update `_isMessageForMe()` in ble_service.dart

### Phase 3: Spy Mode Detection (NEXT)
- Add `_onNoiseHandshakeComplete()` spy mode check
- Implement `onSpyModeDetected` callback
- Create UI dialog for reveal prompt

### Phase 4: FRIEND_REVEAL Protocol (NEXT)
- Add `ProtocolMessageType.friendReveal`
- Implement handler `_handleFriendReveal()`
- Add proof-of-ownership crypto

### Phase 5: Chat Separation (NEXT)
- Update database schema (add `is_spy_mode` column)
- Modify chat creation logic
- Update UI to show both chats

### Phase 6: Settings UI (FINAL)
- Add spy mode toggle to settings screen
- Add help text explaining feature
- Add reveal button in active spy chats

---

## Open Questions

1. **Chat merging**: If user reveals identity, merge chats or keep separate?
   - **Proposal**: User choice via dialog

2. **Relay routing**: Spy mode messages can't be relayed (ephemeral IDs not routable)
   - **Proposal**: Spy mode = direct-only, show "Direct" badge

3. **Group chats**: Can spy mode work in groups?
   - **Proposal**: No, groups require persistent identities

4. **Persistent spy chats**: Should spy chats survive app restart?
   - **Proposal**: Yes, but with warning: "This user might be offline"

---

## Summary

Spy mode provides **privacy-preserving anonymous chat** while maintaining **seamless friend mode** when desired. The key insight: **use hint broadcast status to determine identity tagging**, enabling two distinct chat modes between the same pair without breaking existing functionality.

**Benefits**:
- ✅ Whistleblower protection
- ✅ Plausible deniability
- ✅ Fun "prank mode" for friends
- ✅ Gradual trust building (anonymous → reveal)

**Tradeoffs**:
- ❌ No relay routing in spy mode
- ❌ Potential user confusion (two chats)
- ❌ More complex identity management
