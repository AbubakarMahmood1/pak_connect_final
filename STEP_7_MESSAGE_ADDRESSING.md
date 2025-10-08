# Step 7: Update Message Addressing

**Date:** October 7, 2025
**Status:** Implementation Plan

---

## 🎯 Goal

Update message addressing throughout the system to use:
- **Ephemeral IDs** for unpaired contacts (privacy preserved)
- **Persistent public keys** for paired contacts (secure communication)

The system must automatically determine which ID type to use based on pairing status.

---

## 📋 Current State Analysis

### Message Flow
1. **UI Layer** (`chat_screen.dart`) → User sends message
2. **BLE Service** (`ble_service.dart`) → `sendMessage()` creates protocol message
3. **Mesh Service** (`mesh_networking_service.dart`) → Routes and relays messages
4. **Protocol Message** (`protocol_message.dart`) → Contains recipient addressing

### Current Issues
- Messages always use `otherDevicePersistentId` (may be null for unpaired)
- No differentiation between ephemeral and persistent addressing
- Mesh relay uses persistent keys even for unpaired contacts
- No way to determine pairing status when sending

---

## 🔧 Implementation Plan

### Phase 1: Add Recipient ID Resolution to BLE State Manager

**File:** `lib/data/services/ble_state_manager.dart`

Add method to resolve the appropriate recipient ID:

```dart
/// Get the appropriate ID to use when addressing this contact
/// - Returns persistent public key if paired (after key exchange)
/// - Returns ephemeral ID if not paired (privacy preserved)
String? getRecipientId() {
  // If we have persistent ID, we're paired
  if (_otherDevicePersistentId != null) {
    return _otherDevicePersistentId;
  }
  
  // Otherwise use ephemeral ID
  return _theirEphemeralId;
}

/// Check if we're paired with the current contact
bool get isPaired => _otherDevicePersistentId != null;

/// Get ID type for logging
String getIdType() {
  return isPaired ? 'persistent' : 'ephemeral';
}
```

---

### Phase 2: Update Protocol Message Structure

**File:** `lib/core/models/protocol_message.dart`

Add fields to track recipient information:

```dart
// Add to textMessage constructor
static ProtocolMessage textMessage({
  required String messageId,
  required String content,
  bool encrypted = false,
  String? recipientId,  // NEW: Recipient's ID (ephemeral or persistent)
  bool useEphemeralAddressing = false,  // NEW: Flag for routing
}) => ProtocolMessage(
  type: ProtocolMessageType.textMessage,
  payload: {
    'messageId': messageId,
    'content': content,
    'encrypted': encrypted,
    if (recipientId != null) 'recipientId': recipientId,
    'useEphemeralAddressing': useEphemeralAddressing,
  },
  timestamp: DateTime.now(),
);

// Add helper
String? get recipientId => payload['recipientId'] as String?;
bool get useEphemeralAddressing => payload['useEphemeralAddressing'] as bool? ?? false;
```

---

### Phase 3: Update BLE Service Message Sending

**File:** `lib/data/services/ble_service.dart` (lines ~1567-1590)

Update `sendMessage()` to include recipient ID:

```dart
Future<bool> sendMessage(String message, {String? messageId, String? originalIntendedRecipient}) async {
  if (!_connectionManager.hasBleConnection || _connectionManager.messageCharacteristic == null) {
    throw Exception('Not connected to any device');
  }
  
  int mtuSize = _connectionManager.mtuSize ?? 20;
  
  // Get appropriate recipient ID (ephemeral or persistent)
  final recipientId = _stateManager.getRecipientId();
  final isPaired = _stateManager.isPaired;
  final idType = _stateManager.getIdType();
  
  _logger.info('📤 Sending message using $idType ID: ${recipientId?.substring(0, 16)}...');
  
  return await _messageHandler.sendMessage(
    centralManager: centralManager,
    connectedDevice: _connectionManager.connectedDevice!,
    messageCharacteristic: _connectionManager.messageCharacteristic!,
    message: message,
    mtuSize: mtuSize,
    messageId: messageId,
    contactPublicKey: isPaired ? recipientId : null,  // Only for paired
    recipientId: recipientId,  // NEW: Pass recipient ID
    useEphemeralAddressing: !isPaired,  // NEW: Flag for routing
    originalIntendedRecipient: originalIntendedRecipient,
    contactRepository: _stateManager.contactRepository,
    stateManager: _stateManager,
    onMessageOperationChanged: (inProgress) => _connectionManager.setMessageOperationInProgress(inProgress),
  );
}
```

---

### Phase 4: Update Message Handler

**File:** `lib/data/services/ble_message_handler.dart`

Update `sendMessage()` signature and implementation:

```dart
Future<bool> sendMessage({
  required CentralManager centralManager,
  required DiscoveredDevice connectedDevice,
  required GATTCharacteristic messageCharacteristic,
  required String message,
  required int mtuSize,
  String? messageId,
  String? contactPublicKey,
  String? recipientId,  // NEW
  bool useEphemeralAddressing = false,  // NEW
  String? originalIntendedRecipient,
  required ContactRepository contactRepository,
  required BleStateManager stateManager,
  required Function(bool) onMessageOperationChanged,
}) async {
  // ... existing code ...
  
  final protocolMessage = ProtocolMessage.textMessage(
    messageId: messageId ?? finalMessageId,
    content: message,
    encrypted: isEncrypted,
    recipientId: recipientId,  // NEW
    useEphemeralAddressing: useEphemeralAddressing,  // NEW
  );
  
  // ... rest of implementation ...
}
```

---

### Phase 5: Update Mesh Networking Service

**File:** `lib/domain/services/mesh_networking_service.dart`

Update message routing to check pairing status:

```dart
/// Send message through mesh network (main API for UI)
Future<MeshSendResult> sendMeshMessage({
  required String content,
  required String recipientPublicKey,
  MessagePriority priority = MessagePriority.normal,
  bool isDemo = false,
}) async {
  if (!_isInitialized || _currentNodeId == null) {
    return MeshSendResult.error('Mesh networking not initialized');
  }

  try {
    // Check if this is an ephemeral ID or persistent key
    final contact = await _contactRepository.getContact(recipientPublicKey);
    final isPaired = contact != null && contact.securityLevel != SecurityLevel.none;
    
    final truncatedRecipient = recipientPublicKey.length > 8 
      ? recipientPublicKey.substring(0, 8) 
      : recipientPublicKey;
    
    _logger.info('Sending mesh message to $truncatedRecipient... '
      '(paired: $isPaired, demo: $isDemo)');
    
    // Generate chat ID (using recipient's ID)
    final chatId = ChatUtils.generateChatId(recipientPublicKey);
    
    // Check if direct delivery is possible
    final canDeliverDirectly = await _canDeliverDirectly(recipientPublicKey);
    
    if (canDeliverDirectly) {
      // Direct delivery
      return await _sendDirectMessage(
        content, 
        recipientPublicKey, 
        chatId, 
        isDemo,
        isPaired: isPaired,
      );
    } else {
      // Mesh relay required
      return await _sendMeshRelayMessage(
        content, 
        recipientPublicKey, 
        chatId, 
        priority, 
        isDemo,
        isPaired: isPaired,
      );
    }
    
  } catch (e) {
    _logger.severe('Failed to send mesh message: $e');
    return MeshSendResult.error('Failed to send: $e');
  }
}

/// Send message directly (no relay needed)
Future<MeshSendResult> _sendDirectMessage(
  String content, 
  String recipientPublicKey, 
  String chatId, 
  bool isDemo, {
  required bool isPaired,  // NEW
}) async {
  try {
    _logger.info('📨 Direct message delivery (paired: $isPaired)');
    
    // Queue message for direct delivery
    final messageId = await _messageQueue!.queueMessage(
      chatId: chatId,
      content: content,
      recipientPublicKey: recipientPublicKey,
      senderPublicKey: _currentNodeId!,
    );

    if (isDemo) {
      _trackDemoMessage(messageId, 'direct');
      _demoEventController.add(
        DemoEvent.directMessageSent(messageId, recipientPublicKey)
      );
    }

    final truncatedMessageId = messageId.length > 16 
      ? messageId.substring(0, 16) 
      : messageId;
    _logger.info('Message queued for direct delivery: $truncatedMessageId...');
    return MeshSendResult.direct(messageId);
    
  } catch (e) {
    return MeshSendResult.error('Direct send failed: $e');
  }
}
```

---

### Phase 6: Update Mesh Relay Messages

Update mesh relay to preserve addressing type:

```dart
static ProtocolMessage meshRelay({
  required String originalMessageId,
  required String originalSender,
  required String finalRecipient,
  required Map<String, dynamic> relayMetadata,
  required Map<String, dynamic> originalPayload,
  bool useEphemeralAddressing = false,  // NEW
}) => ProtocolMessage(
  type: ProtocolMessageType.meshRelay,
  payload: {
    'originalMessageId': originalMessageId,
    'originalSender': originalSender,
    'finalRecipient': finalRecipient,
    'relayMetadata': relayMetadata,
    'originalPayload': originalPayload,
    'useEphemeralAddressing': useEphemeralAddressing,  // NEW
  },
  timestamp: DateTime.now(),
);
```

---

## 🧪 Testing Plan

### Test Cases

1. **Unpaired Contact Messaging**
   - Create connection without pairing
   - Send message
   - Verify uses ephemeral ID
   - Verify message received

2. **Paired Contact Messaging**
   - Complete pairing flow
   - Send message
   - Verify uses persistent public key
   - Verify message received

3. **Transition from Unpaired to Paired**
   - Send message (ephemeral)
   - Complete pairing
   - Send another message (persistent)
   - Verify both messages in same chat (after migration)

4. **Mesh Relay with Ephemeral**
   - Unpaired contact not directly connected
   - Send message through relay
   - Verify relay preserves ephemeral addressing

5. **Mesh Relay with Persistent**
   - Paired contact not directly connected
   - Send message through relay
   - Verify relay uses persistent keys

---

## 📝 File Changes Summary

1. **`lib/data/services/ble_state_manager.dart`**
   - Add `getRecipientId()` method
   - Add `isPaired` getter
   - Add `getIdType()` method

2. **`lib/core/models/protocol_message.dart`**
   - Add `recipientId` field to textMessage
   - Add `useEphemeralAddressing` field
   - Add helpers for new fields
   - Update meshRelay constructor

3. **`lib/data/services/ble_service.dart`**
   - Update `sendMessage()` to resolve recipient ID
   - Pass pairing status to message handler
   - Add logging for ID type

4. **`lib/data/services/ble_message_handler.dart`**
   - Update `sendMessage()` signature
   - Include recipient ID in protocol message
   - Pass ephemeral addressing flag

5. **`lib/domain/services/mesh_networking_service.dart`**
   - Check pairing status before routing
   - Pass pairing status to direct/relay methods
   - Update relay messages with addressing type

---

## ✅ Expected Outcomes

1. ✅ Messages to unpaired contacts use ephemeral IDs (privacy preserved)
2. ✅ Messages to paired contacts use persistent keys (secure)
3. ✅ System automatically determines correct addressing
4. ✅ Mesh relay preserves addressing type
5. ✅ Chat migration works seamlessly
6. ✅ No breaking changes to existing functionality

---

## 🚀 Next Steps After Completion

- **Phase 8:** Update Discovery Overlay to show contact names after pairing
- **Phase 9:** Add UI indicators for pairing status
- **Phase 10:** Implement contact verification flows
- **Phase 11:** Add security warnings for key changes
- **Phase 12:** Complete end-to-end testing
