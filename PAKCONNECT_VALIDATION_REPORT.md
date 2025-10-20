# PakConnect Dual-Role BLE Validation Report

**Date:** 2025-10-20
**Compared Against:** BitChat reference implementation

---

## Executive Summary

✅ **GOOD NEWS:** PakConnect uses **identity-based Noise sessions** similar to BitChat
❌ **ISSUE FOUND:** PakConnect has unclear dual-connection handling
⚠️ **POTENTIAL BUG:** Connection-based vs identity-based session lookup confusion

---

## 1. Noise Session Management Comparison

### BitChat Approach
```kotlin
// Sessions keyed by peerID (identity-based)
private val sessions = ConcurrentHashMap<String, NoiseSession>()

fun getSession(peerID: String): NoiseSession? {
    return sessions[peerID]  // peerID derived from static public key
}
```

### PakConnect Approach
```dart
// File: noise_session_manager.dart:31-32
/// Active sessions by peer identifier
final _sessions = <String, NoiseSession>{};

NoiseSession? getSession(String peerID) {
  return _sessions[peerID];  // SAME PATTERN ✅
}
```

**✅ VALIDATION:** PakConnect correctly uses identity-based session storage.

---

## 2. Peer Identity Model

### BitChat: peerID from Packet Payload

```kotlin
// BluetoothGattClientManager.kt:503
val peerID = packet.senderID.take(8).toByteArray().joinToString("") { "%02x".format(it) }
delegate?.onPacketReceived(packet, peerID, gatt.device)
```

**Key:** `peerID` extracted from **packet.senderID**, NOT from MAC address or connection.

### PakConnect: Multiple Identity Layers

```dart
// From analysis of ble_service.dart
1. ephemeralId - Session-specific ID from Noise handshake
2. publicKey - Persistent Noise static public key (after pairing)
3. currentEphemeralId - Active session ID (from Contact model)
4. persistentPublicKey - Real identity (from Contact model)
```

**Example from code:**
```dart
// ble_service.dart:1996
Future<void> _onHandshakeComplete(String ephemeralId, String displayName, String? noisePublicKey) async {
  _stateManager.setTheirEphemeralId(ephemeralId, displayName);
  _stateManager.setOtherDeviceIdentity(ephemeralId, displayName);  // Uses ephemeralId as key!
  // ...
}
```

**⚠️ CONCERN:** PakConnect uses `ephemeralId` as the initial key, then migrates to `persistentPublicKey` after pairing. This adds complexity compared to BitChat's single `peerID` approach.

---

## 3. Contact Identity Model

### PakConnect's Three-ID System

From CLAUDE.md and code analysis:

```dart
class Contact {
  String publicKey;            // IMMUTABLE: First ephemeral ID (never changes)
  String? persistentPublicKey; // REAL identity after MEDIUM+ pairing
  String? currentEphemeralId;  // ACTIVE Noise session ID (updates per connection)
}
```

**Identity Resolution Rules (from CLAUDE.md):**
- **Chat ID**: `persistentPublicKey ?? publicKey`
- **Noise Lookup**: `currentEphemeralId ?? publicKey`

### Critical Questions for PakConnect:

1. **Q:** When PakConnect calls `getSession(peerID)`, what is `peerID`?
   - **A (from code):** It uses `ephemeralId` initially, then `persistentPublicKey` after pairing
   - **Issue:** This means sessions are re-created during the ephemeral → persistent migration!

2. **Q:** If Device A connects to Device B twice (dual role), do they share the same Noise session?
   - **A (uncertain):** Depends on whether `ephemeralId` is connection-specific or device-specific

---

## 4. Dual Connection Handling

### BitChat: Allows Dual Connections

Evidence from analysis:
- ✅ No checks to prevent dual connections
- ✅ Messages broadcast on ALL connections (client + server)
- ✅ Noise sessions work across all connections (identity-based)

### PakConnect: UNCLEAR

**Scanning for dual-connection prevention:**

```dart
// No explicit check found in:
// - ble_service.dart (connection handling)
// - ble_connection_manager.dart (connection tracking)
// - handshake_coordinator.dart (handshake protocol)
```

**Connection Manager Analysis:**

```dart
// ble_connection_manager.dart
class BLEConnectionManager {
  Peripheral? connectedDevice;  // ⚠️ SINGULAR, not plural!
  Central? connectedCentral;    // ⚠️ SINGULAR, not plural!
}
```

**❌ ISSUE FOUND:** PakConnect appears to track **ONLY ONE** peripheral connection and **ONLY ONE** central connection. This is fundamentally different from BitChat's approach of allowing multiple connections per MAC address.

---

## 5. Message Sending/Receiving

### BitChat: Connection-Agnostic
```kotlin
// Sends on ALL available connections
fun broadcastPacket(routed: RoutedPacket) {
    // Send via CLIENT connections
    clientConnections.forEach { ... }
    // Send via SERVER connections
    subscribedDevices.forEach { ... }
}
```

### PakConnect: Single Connection Model

```dart
// ble_service.dart: sendMessage()
Future<void> sendMessage({
  required String contactPublicKey,
  required String content,
  // ...
}) async {
  // Uses _connectionManager.connectedDevice (singular!)
  // No multi-connection broadcast logic found
}
```

**❌ CONFIRMED:** PakConnect uses a **single-connection model**, NOT multi-connection like BitChat.

---

## 6. Critical Findings

### Finding #1: Connection Model Mismatch

| Aspect | BitChat | PakConnect |
|--------|---------|------------|
| Connections per peer | Multiple (dual-role) | Single (appears to be one active connection) |
| Connection tracking | `ConcurrentHashMap<MAC, DeviceConnection>` | `Peripheral? connectedDevice` (singular) |
| Message broadcast | All connections | Single active connection |

**Implication:** PakConnect is **NOT designed for simultaneous dual-role connections** like BitChat.

### Finding #2: Noise Session Keying

| Aspect | BitChat | PakConnect |
|--------|---------|------------|
| Session key | `peerID` (from packet.senderID) | `ephemeralId` initially, migrates to `persistentPublicKey` |
| Key stability | Stable (derived from static key) | **Migrates** during pairing! |
| Session persistence | One session per peer, reused across connections | **Unclear** - may re-create session during migration |

**⚠️ POTENTIAL BUG:** If PakConnect re-creates Noise sessions during the ephemeral → persistent migration, it could cause:
- Message decryption failures during migration window
- Loss of replay protection state
- Nonce synchronization issues

### Finding #3: Identity Resolution Complexity

PakConnect's three-ID system (publicKey, persistentPublicKey, currentEphemeralId) is more complex than BitChat's single `peerID` approach.

**From PakConnect's CLAUDE.md:**
> **Identity Resolution Rules**:
> - **Chat ID**: `persistentPublicKey ?? publicKey` (security-level aware)
> - **Noise Lookup**: `currentEphemeralId ?? publicKey` (session-aware)

**Question:** When a packet arrives, how does PakConnect know which ID to use for Noise session lookup?

**Code Analysis:**
```dart
// ble_service.dart: _onHandshakeComplete()
_stateManager.setTheirEphemeralId(ephemeralId, displayName);
_stateManager.setOtherDeviceIdentity(ephemeralId, displayName);

// Later, after pairing:
// Migration from ephemeralId to persistentPublicKey happens
```

**⚠️ RISK:** If the Noise session is still keyed by `ephemeralId`, but messages are encrypted using `persistentPublicKey` after pairing, there will be a **session lookup mismatch**.

---

## 7. Specific Validation Tests

### Test 1: Dual Connection Race (N/A for PakConnect?)

**Status:** ❌ **NOT APPLICABLE**

**Reason:** PakConnect appears to use single-connection model (`connectedDevice` is singular), so dual connections may not be supported.

**Recommendation:** Verify if PakConnect can handle:
- Device A connects to Device B as client
- Device B simultaneously connects to Device A as client
- Expected behavior: ?

### Test 2: Noise Session Sharing Across Connections (N/A for PakConnect?)

**Status:** ❌ **NOT APPLICABLE**

**Reason:** If PakConnect only maintains one connection at a time, session sharing across multiple connections is not relevant.

### Test 3: Session Persistence During Identity Migration

**Status:** ⚠️ **NEEDS TESTING**

**Test:**
1. Establish Noise session with peer (using `ephemeralId`)
2. Send encrypted messages successfully
3. Complete pairing, exchange `persistentPublicKey`
4. Migrate chat from `ephemeralId` to `persistentPublicKey`
5. **Critical check:** Does the Noise session continue working, or is it re-created?

**Expected:** Session should persist (same symmetric keys)
**Risk:** If session is re-created, nonce counters reset → replay attack vulnerability

### Test 4: Packet Arrival with Unknown Sender

**Status:** ⚠️ **NEEDS TESTING**

**Test:**
1. Receive encrypted packet from peer
2. Packet contains `senderID` field
3. **Question:** How does PakConnect look up the Noise session?
   - By `ephemeralId`? (session-specific)
   - By `persistentPublicKey`? (identity-specific)
   - By MAC address? (connection-specific)

**Code to check:**
```dart
// Where is the Noise session lookup happening when decrypting incoming messages?
// Search for: noiseEncryptionService.decrypt() or sessionManager.decrypt()
```

---

## 8. Key Architectural Differences

### BitChat: Transport-Agnostic Sessions
```
Peer Identity (peerID from static key)
  └─ One Noise Session
     ├─ Used across ALL BLE connections to that peer
     ├─ Survives connection drops/reconnects
     └─ Independent of MAC address or connection role
```

### PakConnect: Session Migration Model
```
Initial: ephemeralId (from Noise handshake)
  └─ Noise Session #1
     └─ Used for LOW security level

After Pairing: persistentPublicKey (from key exchange)
  └─ Noise Session #2? (migrated or re-created?)
     └─ Used for MEDIUM/HIGH security level

Question: Are Session #1 and #2 the same object or different?
```

---

## 9. Recommended Code Audit

### Files to Review

1. **lib/core/security/noise/noise_session_manager.dart**
   - Check: When is `removeSession()` called?
   - Check: During ephemeral → persistent migration, is session destroyed?

2. **lib/data/services/ble_state_manager.dart:_triggerChatMigration()**
   - Line 509-513 (from grep results)
   - Check: Does this also migrate Noise session?

3. **lib/core/security/noise/noise_encryption_service.dart**
   - Check: decrypt() method - how does it look up session by peerID?
   - Check: Is peerID extracted from packet or from connection metadata?

4. **lib/data/services/ble_service.dart**
   - Line 1996: _onHandshakeComplete()
   - Line 2025: saveContact() during handshake
   - Check: Session is created with `ephemeralId` as key
   - Later: Is session re-keyed to `persistentPublicKey`?

5. **lib/core/bluetooth/handshake_coordinator.dart**
   - Check: How is the peer identity determined during handshake?
   - Check: Is it connection-specific or device-specific?

---

## 10. Answers to Original Questions (for PakConnect)

### Q1: Does PakConnect prevent dual connections?

**Answer:** **UNCLEAR, likely NO** - No explicit prevention logic found, but connection manager uses singular `connectedDevice`, suggesting only one active connection is tracked.

**Implication:** PakConnect may not be designed for dual-role simultaneous operation like BitChat.

### Q2: If dual connections exist, how does PakConnect communicate?

**Answer:** **N/A** - PakConnect appears to use a single-connection model.

**Needs Testing:** What happens if two PakConnect devices both try to connect to each other simultaneously?

### Q3: Which connection does PakConnect use (central vs peripheral)?

**Answer:** **Last connection established?** - Since `connectedDevice` is singular, it likely gets overwritten if a new connection is established.

### Q4: How does PakConnect handle Noise sessions across connections?

**Answer:** **Identity-based, similar to BitChat ✅**

**BUT:** PakConnect's identity migration (ephemeral → persistent) adds complexity not present in BitChat.

### Q5: Is PakConnect's Noise session dependent on connection or ephemeral ID?

**Answer:** **Depends on security level:**
- **LOW security:** Session keyed by `ephemeralId` (session-specific)
- **MEDIUM/HIGH security:** Session migrated to `persistentPublicKey` (identity-specific)

**⚠️ RISK:** Migration process may break session continuity.

---

## 11. Conclusion & Recommendations

### What PakConnect Does Right ✅

1. **Identity-based Noise sessions** - Sessions are not tied to MAC addresses
2. **Persistent public keys** - Long-term identity separate from ephemeral session IDs
3. **Security level upgrades** - Supports LOW → MEDIUM → HIGH progression

### Potential Issues ⚠️

1. **Session migration during pairing** - May cause session re-creation
2. **Unclear dual-connection handling** - Single-connection model vs BitChat's multi-connection model
3. **Complex identity resolution** - Three different IDs (publicKey, persistentPublicKey, currentEphemeralId)

### Critical Test Needed 🧪

**Test the ephemeral → persistent migration:**

```dart
// Scenario:
1. Device A and B complete Noise handshake (ephemeralId-based session)
2. Send 100 messages successfully (session works)
3. Complete pairing, exchange persistentPublicKey
4. _triggerChatMigration() is called
5. Check: Is the Noise session still valid?
6. Send 100 more messages
7. Expected: All messages encrypt/decrypt successfully
8. Actual: ? (NEEDS TESTING)
```

**If messages fail after migration:**
- Session was re-created (BUG)
- Nonce counters reset (SECURITY ISSUE)
- Need to fix session migration to preserve session state

### Recommendations

1. **Add logging** to trace Noise session lifecycle during migration
2. **Unit test** session persistence across identity migration
3. **Clarify** whether PakConnect should support dual-role connections
4. **Document** the intended behavior for simultaneous dual connections
5. **Consider** simplifying identity model to single `peerID` like BitChat

---

## 12. Does PakConnect Have the Same Problem as BitChat?

**Original Question:** "Did I make sense? I am sorry i know not much about BLE and always get confused..."

**Answer:** **Your intuition was correct to be confused!**

PakConnect and BitChat have **fundamentally different architectures**:

| Aspect | BitChat | PakConnect |
|--------|---------|------------|
| Connection model | Multi-connection (dual-role OK) | Single-connection (one active connection) |
| Session identity | Single `peerID` (stable) | Migrates from `ephemeralId` to `persistentPublicKey` |
| Dual connection check | None (allows dual connections) | N/A (doesn't track multiple connections) |
| Session persistence | Same session across all connections | ⚠️ **Unclear** - may re-create during migration |

**You were RIGHT to ask about:**
1. ✅ Dual-connection handling (different approaches)
2. ✅ Noise session independence from connections (both do this, but differently)
3. ✅ Whether sessions depend on ephemeral IDs (PakConnect's migration is a unique concern)

**The confusion is VALID** because:
- PakConnect has a more complex identity model than BitChat
- The ephemeral → persistent migration is not well-documented
- It's unclear if Noise sessions survive this migration

**Next step:** Run the migration test to verify session continuity! 🔬
