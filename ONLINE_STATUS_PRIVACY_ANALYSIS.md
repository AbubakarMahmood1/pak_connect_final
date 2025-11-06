# Online Status Privacy Issue - Analysis & Solution

## 🔴 CRITICAL PRIVACY ISSUE IDENTIFIED

### Problem Summary

The current online status system **leaks identity across ephemeral sessions** for LOW-security contacts, defeating the purpose of ephemeral key rotation.

---

## Root Cause Analysis

### 1. **Hint System Behavior**

**Current Flow**:
```
LOW Security Contact Created (after Noise handshake)
  ↓
Shared Secret = NULL (no pairing, no ECDH)
  ↓
HintCacheManager.updateCache() runs
  ↓
For each contact: getCachedSharedSecret(publicKey)
  ↓
If sharedSecret != null: Generate hint and cache it
  ↓
LOW contacts have NO shared secret → NO hints generated ✅
```

**HOWEVER**, there's a **critical leak**:

### 2. **The Leak: Intro Hints Persist**

**Scenario**:
1. User scans QR code → `IntroHintRepository.saveScannedHint()` stores hint
2. User connects to device → Handshake completes → Contact created at LOW security
3. **Intro hint is NEVER deleted** → Remains in `IntroHintRepository`
4. Device advertises with **same intro hint** on next connection
5. `DeviceDeduplicationManager._verifyContactAsync()` matches hint → `isKnownContact = true`
6. `_isContactOnlineViaHash()` checks `device.isKnownContact` → Returns TRUE
7. **ALL chats with that contact turn green** (even old ephemeral sessions)

**Code Evidence**:
```dart
// lib/core/discovery/device_deduplication_manager.dart:64
static void _verifyContactAsync(DiscoveredDevice device) async {
  final contactHint = HintCacheManager.getContactFromCache(device.ephemeralHint);
  device.isKnownContact = contactHint != null;  // ❌ LEAK: Intro hints also match!
  device.contactInfo = contactHint?.contact;
  // ...
}

// lib/presentation/screens/home_screen.dart:869
if (device.isKnownContact && 
    device.contactInfo?.publicKey == contactPublicKey) {  // ❌ Matches ANY publicKey
  return true;  // All chats turn green!
}
```

### 3. **Multiple Chats Problem**

**Why multiple chats exist**:
```dart
// lib/core/utils/chat_utils.dart:24
static String generateChatId(String theirId) {
  return theirId;  // chatId = their ephemeral ID
}
```

**Result**:
- First connection: `chatId = ephemeralId_1` (LOW security)
- Second connection: `chatId = ephemeralId_2` (LOW security, new session)
- **Two separate chats** for the same person (by design for privacy)

**But online status leaks identity**:
- User connects with `ephemeralId_2`
- Intro hint matches → `device.contactInfo.publicKey = ephemeralId_1` (first contact)
- `_isContactOnlineViaHash()` checks `ephemeralId_1` → **OLD chat turns green**
- Also checks `ephemeralId_2` → **NEW chat turns green**
- **Both chats online** → User knows it's the same person!

---

## Security Levels & Shared Secrets

### When Shared Secrets Exist

| Security Level | Shared Secret Source | Hint Generation | Identity Persistence |
|----------------|---------------------|-----------------|---------------------|
| **LOW** | None (Noise only) | ❌ No hints | ❌ Ephemeral per session |
| **MEDIUM** | PIN pairing (SHA256 of codes) | ✅ Session-based hints | ✅ Persistent via `persistentPublicKey` |
| **HIGH** | ECDH (X25519 DH) | ✅ Cryptographic hints | ✅ Verified identity |

**Code Evidence**:
```dart
// lib/core/security/hint_cache_manager.dart:52
for (final contact in contacts.values) {
  final sharedSecret = await contactRepo.getCachedSharedSecret(contact.publicKey);
  if (sharedSecret != null) {  // ✅ Only MEDIUM+ have secrets
    final hint = EphemeralKeyManager.generateContactHint(
      contact.publicKey,
      sharedSecret
    );
    _hintCache[hint] = ContactHint(enhancedContact, sharedSecret);
  }
}
```

**Conclusion**: LOW contacts should NEVER have hints, but **intro hints bypass this**.

---

## Solution Design

### Principle: **Intro Hints Are Temporary Discovery Aids**

Intro hints should be **deleted after first successful connection** to prevent identity linkage across sessions.

### Implementation Strategy

#### 1. **Delete Intro Hint After Handshake Completion**

**Location**: `lib/data/services/ble_state_manager.dart` (after handshake)

**Logic**:
```dart
// After successful handshake at LOW security:
if (securityLevel == SecurityLevel.low) {
  // Check if this was an intro hint connection
  final introHintRepo = IntroHintRepository();
  final scannedHints = await introHintRepo.getScannedHints();
  
  // Find matching hint (if any)
  for (final hint in scannedHints.values) {
    if (hint.displayName == displayName || hint.publicKeyHint == ephemeralId) {
      // Delete the intro hint - it served its purpose
      await introHintRepo.removeScannedHint(hint.hintHex);
      _logger.info('🗑️ Deleted intro hint after LOW security connection: ${hint.hintHex}');
      break;
    }
  }
}
```

#### 2. **Fix Online Status Logic - Only Current Session**

**Location**: `lib/presentation/screens/home_screen.dart`

**Current Logic** (BROKEN):
```dart
bool _isContactOnlineViaHash(String contactPublicKey, Map<String, DiscoveredDevice> discoveryData) {
  for (final device in discoveryData.values) {
    if (device.isKnownContact && 
        device.contactInfo?.publicKey == contactPublicKey) {  // ❌ Matches old sessions
      return true;
    }
  }
  return false;
}
```

**Fixed Logic**:
```dart
bool _isContactOnlineViaHash(String contactPublicKey, Map<String, DiscoveredDevice> discoveryData) {
  for (final device in discoveryData.values) {
    if (device.isKnownContact && device.contactInfo != null) {
      final contact = device.contactInfo!.contact;
      
      // ✅ FIX: Match by currentEphemeralId for active session
      if (contact.currentEphemeralId == contactPublicKey) {
        return true;  // Current session is online
      }
      
      // ✅ FIX: Match by persistentPublicKey for MEDIUM+ contacts
      if (contact.persistentPublicKey != null && 
          contact.persistentPublicKey == contactPublicKey) {
        return true;  // Paired contact is online
      }
    }
  }
  return false;
}
```

#### 3. **Update Contact's currentEphemeralId on Connection**

**Location**: `lib/data/services/ble_state_manager.dart` (after handshake)

**Ensure**:
```dart
// After handshake completes:
await _contactRepository.updateContactEphemeralId(publicKey, currentEphemeralId);
```

This already exists but verify it's called for ALL security levels.

---

## Expected Behavior After Fix

### Scenario 1: LOW Security (Ephemeral Sessions)

**First Connection**:
1. Scan QR → Intro hint saved
2. Connect → Handshake → Contact created (`publicKey = ephemeral_1`)
3. **Intro hint deleted** ✅
4. Chat created (`chatId = ephemeral_1`)
5. Online status: **Only this chat turns green** ✅

**Second Connection** (same person, new session):
1. No intro hint (deleted)
2. Connect → Handshake → **New contact** created (`publicKey = ephemeral_2`)
3. New chat created (`chatId = ephemeral_2`)
4. Online status: **Only new chat turns green** ✅
5. **Old chat stays offline** ✅ (privacy preserved!)

### Scenario 2: MEDIUM+ Security (Persistent Identity)

**First Connection**:
1. Scan QR → Intro hint saved
2. Connect → Handshake → Pairing → Contact upgraded to MEDIUM
3. **Intro hint deleted** ✅ (no longer needed)
4. Shared secret generated → Persistent hints enabled
5. `persistentPublicKey` set → Chat ID uses persistent key

**Second Connection**:
1. Persistent hint matches → Auto-connect (if enabled)
2. Same contact updated (`currentEphemeralId = new_session_id`)
3. **Same chat** (uses `persistentPublicKey`)
4. Online status: **Chat turns green** ✅

---

## Implementation Checklist

- [ ] Add intro hint deletion after LOW security handshake
- [ ] Fix `_isContactOnlineViaHash()` to use `currentEphemeralId`
- [ ] Verify `updateContactEphemeralId()` is called on every connection
- [ ] Add logging for hint deletion (🗑️ emoji)
- [ ] Add logging for online status matching (🟢 emoji)
- [ ] Test: Two LOW connections should create separate chats
- [ ] Test: Only active session chat should show online
- [ ] Test: MEDIUM+ contacts should persist across sessions

---

## Files to Modify

1. **lib/data/services/ble_state_manager.dart** - Delete intro hints after handshake
2. **lib/presentation/screens/home_screen.dart** - Fix online status matching logic
3. **lib/data/repositories/intro_hint_repository.dart** - Verify `removeScannedHint()` works correctly

---

## Privacy Impact

**Before Fix**:
- ❌ Intro hints persist forever
- ❌ All chats with same person turn green
- ❌ Identity linkable across ephemeral sessions
- ❌ Ephemeral key rotation is useless

**After Fix**:
- ✅ Intro hints deleted after first use
- ✅ Only current session chat turns green
- ✅ Identity NOT linkable across sessions
- ✅ Ephemeral key rotation provides real privacy

