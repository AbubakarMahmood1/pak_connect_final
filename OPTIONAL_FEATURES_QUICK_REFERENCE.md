# 🚀 Quick Reference: Optional Features

## ✅ What Was Implemented

### 1. **Markdown Privacy Policy** 📄
- **Location**: Settings → Privacy & Security → Privacy Policy
- **What**: Professional markdown-formatted privacy policy with styled rendering
- **File**: `assets/privacy_policy.md`

### 2. **Online Status Toggle** 🔒
- **Location**: Settings → Privacy & Security → Show Online Status
- **What**: Hide your identity hint from BLE broadcasts
- **Impact**: 
  - ON (default): Contacts can recognize you
  - OFF: Only intro hint broadcasts (no identity)

### 3. **Allow New Contacts** 🚫
- **Location**: Settings → Privacy & Security → Allow New Contacts
- **What**: Auto-reject incoming contact requests
- **Impact**:
  - ON (default): Contact requests show dialog
  - OFF: Requests auto-rejected silently

### 4. **Clear All Caches** 🧹
- **Location**: Settings → Developer Tools → Clear All Caches
- **What**: Clears in-memory caches and rotates ephemeral session
- **Clears**:
  - Conversation keys (pairing)
  - Message cache (replay protection)
  - Hint cache (BLE advertisements)
  - Ephemeral session (rotates keys)
- **Preserves**:
  - Contact relationships
  - Chat history
  - ECDH secrets in secure storage

---

## 🔧 Technical Implementation

### Online Status (BLE Integration)
```dart
// lib/data/services/ble_service.dart (line ~1152)
final showOnlineStatus = prefs.getBool('show_online_status') ?? true;
final myPersistentHint = showOnlineStatus 
  ? SensitiveContactHint.compute(contactPublicKey: myPublicKey)
  : null; // Broadcasts zeros instead of identity hint
```

### Allow New Contacts (Auto-Reject)
```dart
// lib/data/services/ble_state_manager.dart (line ~1321)
Future<void> handleContactRequest(...) async {
  final allowNewContacts = prefs.getBool('allow_new_contacts') ?? true;
  if (!allowNewContacts) {
    onSendContactReject?.call(); // Silent rejection
    return;
  }
  // Show dialog...
}
```

### Cache Clearing
```dart
// lib/presentation/screens/settings_screen.dart (line ~1326)
SimpleCrypto.clearAllConversationKeys();
await MessageSecurity.clearProcessedMessages();
HintCacheManager.clearCache();
await EphemeralKeyManager.rotateSession();
```

---

## 🧪 Single-Device Testing

All 4 features can be tested on a single device:

1. **Privacy Policy**: Just open and read
2. **Online Status**: Toggle and check logs (`📡 Online Status: visible/hidden`)
3. **Allow New Contacts**: Toggle ON/OFF (test with second device)
4. **Clear Caches**: Tap button, verify snackbar, reconnect to contact

---

## 📊 Settings Screen Status

**Total Features**: 17  
**Implemented**: 14/17 (82%)

**Single-Device Complete**: ✅ 14/14  
**Multi-Device Remaining**: 3/3 (background, range, battery)

---

## 🎯 What's Next?

All single-device testable features are done! Remaining items require multi-device setup:
- Background Services (platform-specific)
- BLE Range Indicator (RSSI from connections)
- Battery Optimization (multi-device power testing)

---

**Ready for Testing!** 🎉
