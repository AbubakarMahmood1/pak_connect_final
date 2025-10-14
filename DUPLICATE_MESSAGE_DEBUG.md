# Duplicate Message Investigation - Debugging Guide

## Problem Statement
Messages appear twice when:
1. User opens chat (messages show correctly once)
2. User navigates to ChatsScreen
3. New messages arrive (show once - correct)
4. User returns to chat
5. **NEW messages after staying in chat show TWICE**

## Hypothesis: Double Subscription Issue

Based on code analysis, there are **TWO** potential message delivery paths:

### Path 1: Persistent Manager (Intended)
```
BLE Service → Stream → Persistent Manager → Active Handler → _addReceivedMessage()
```

### Path 2: Direct Subscription (Potential Duplicate)
```
BLE Service → Stream → Direct Subscription → _addReceivedMessage()
```

## Key Suspects

### 1. **Multiple Stream Listeners**
- `_activateMessageListener()` is called which sets up persistent manager
- BUT if persistent manager already has a listener, it might still set up a direct subscription
- This would cause **double delivery** of every message

### 2. **Re-registration Without Cleanup**
- When returning to chat screen, `_setupPersistentChatManager()` registers handler
- The persistent listener stream might deliver buffered messages
- Then ALSO deliver new messages because the handler is registered

### 3. **Persistent Listener Not Properly Cleaned**
- Even though we "unregister" on dispose, the StreamSubscription persists
- This is INTENTIONAL for buffering
- But on re-open, we might create a SECOND subscription

## Debug Logging Added

### 🟢 BLE Service (ble_service.dart)
```dart
print('🟢🟢🟢 BLE_SERVICE EMITTING MESSAGE TO STREAM 🟢🟢🟢');
```
- Shows when BLE service emits to stream
- Shows number of listeners

### 🟡 Persistent Manager (persistent_chat_state_manager.dart)
```dart
print('🟡🟡🟡 PERSISTENT MANAGER RECEIVED MESSAGE 🟡🟡🟡');
```
- Shows when persistent manager receives from stream
- Shows if chat is active
- Shows if delivering or buffering

### 🔵 Chat Screen Listener Setup (chat_screen.dart)
```dart
print('🔵🔵🔵 _activateMessageListener: SETTING UP LISTENER 🔵🔵🔵');
```
- Shows when listener is activated
- Shows if persistent manager has listener
- Shows if using persistent OR direct subscription

### 🟣 Chat Manager Setup (chat_screen.dart)
```dart
print('🟣🟣🟣 _setupPersistentChatManager CALLED 🟣🟣🟣');
```
- Shows registration with persistent manager
- Shows debug info before/after registration

### 🔴 Message Processing (chat_screen.dart)
```dart
print('🔴🔴🔴 _addReceivedMessage CALLED 🔴🔴🔴');
```
- **MOST IMPORTANT**: Shows every call to _addReceivedMessage
- Shows full stack trace to see WHO called it
- Shows if message is duplicate or new

## How to Test

### Test Scenario
1. Connect two devices
2. Open chat
3. Send message from Device A to Device B ✅ (should show once)
4. On Device B, navigate back to ChatsScreen
5. Send another message from Device A
6. On Device B, re-open the chat
7. **Stay in the chat** (don't navigate away)
8. Send a new message from Device A
9. **Watch the console logs**

### What to Look For

#### If Message Shows ONCE (Correct):
```
🟢 BLE_SERVICE EMITTING MESSAGE TO STREAM
🟡 PERSISTENT MANAGER RECEIVED MESSAGE
🟡 ➡️ DELIVERING TO ACTIVE CHAT SCREEN
🔴 _addReceivedMessage CALLED (ONE TIME)
🔴 ✅ NEW MESSAGE - PROCEEDING TO SAVE
```

#### If Message Shows TWICE (Bug):

**Scenario A: Double Listener**
```
🟢 BLE_SERVICE EMITTING MESSAGE TO STREAM
🟡 PERSISTENT MANAGER RECEIVED MESSAGE
🟡 ➡️ DELIVERING TO ACTIVE CHAT SCREEN
🔴 _addReceivedMessage CALLED (FIRST TIME)
🔵 Direct subscription received message
🔴 _addReceivedMessage CALLED (SECOND TIME - DUPLICATE!)
```

**Scenario B: Double Registration**
```
🟢 BLE_SERVICE EMITTING MESSAGE TO STREAM
🟡 PERSISTENT MANAGER RECEIVED MESSAGE
🟡 ➡️ DELIVERING TO ACTIVE CHAT SCREEN
🔴 _addReceivedMessage CALLED (FIRST TIME)
🟡 PERSISTENT MANAGER RECEIVED MESSAGE (AGAIN?!)
🟡 ➡️ DELIVERING TO ACTIVE CHAT SCREEN
🔴 _addReceivedMessage CALLED (SECOND TIME - DUPLICATE!)
```

**Scenario C: DB Not Catching Duplicate**
```
🟢 BLE_SERVICE EMITTING MESSAGE TO STREAM
🟡 PERSISTENT MANAGER RECEIVED MESSAGE
🔴 _addReceivedMessage CALLED (FIRST TIME)
🔴 ✅ NEW MESSAGE - PROCEEDING TO SAVE
🔴 _addReceivedMessage CALLED (SECOND TIME)
🔴 ✅ NEW MESSAGE - PROCEEDING TO SAVE (Should have been DUPLICATE!)
```

## Stack Trace Analysis

When you see `🔴 _addReceivedMessage CALLED`, look at the stack trace:

### Expected (Correct):
```
_handlePersistentMessage → _addReceivedMessage
```

### Problem Patterns:

**Pattern 1: Direct Subscription Active**
```
<anonymous closure> → _addReceivedMessage
(from _activateMessageListener direct subscription)
```

**Pattern 2: Both Active**
```
First call: _handlePersistentMessage → _addReceivedMessage
Second call: <anonymous closure> → _addReceivedMessage
```

## Next Steps Based on Findings

### If Double Listener Found:
➡️ Fix: Ensure `_activateMessageListener()` never creates direct subscription when persistent manager exists

### If Double Registration Found:
➡️ Fix: Ensure persistent manager doesn't deliver messages twice to same handler

### If DB Duplicate Check Failing:
➡️ Fix: Message ID generation might not be deterministic
➡️ Check if `MessageSecurity.generateSecureMessageId()` produces same ID for same content

## Potential Fixes (Don't Apply Yet)

### Fix 1: Prevent Direct Subscription When Persistent Manager Exists
```dart
void _activateMessageListener() {
  if (_messageListenerActive) return;
  
  _messageListenerActive = true;
  final bleService = ref.read(bleServiceProvider);
  
  // ONLY use persistent manager, NEVER create direct subscription
  if (_persistentChatManager != null) {
    if (!_persistentChatManager!.hasActiveListener(_chatId)) {
      _persistentChatManager!.setupPersistentListener(_chatId, bleService.receivedMessages);
    }
    // DO NOT create fallback subscription
  }
}
```

### Fix 2: Prevent Duplicate Deliveries in Persistent Manager
```dart
// Add delivery tracking in PersistentChatStateManager
final Map<String, Set<String>> _deliveredMessageIds = {};

void _deliverMessage(String chatId, String content) {
  // Generate hash of content
  final contentHash = content.hashCode.toString();
  
  _deliveredMessageIds[chatId] ??= {};
  
  if (_deliveredMessageIds[chatId]!.contains(contentHash)) {
    print('🟡 ⚠️ DUPLICATE DELIVERY BLOCKED');
    return;
  }
  
  _deliveredMessageIds[chatId]!.add(contentHash);
  _activeMessageHandlers[chatId]!(content);
}
```

### Fix 3: Ensure Message ID is Deterministic
Check `MessageSecurity.generateSecureMessageId()` to ensure it produces the same ID for the same content+sender combination.

---

## Instructions for User

1. **Connect two devices and reproduce the issue**
2. **Copy the ENTIRE console output** when sending the duplicate message
3. **Look for the patterns above** in the logs
4. **Report back with**:
   - How many times you see `🟢 BLE_SERVICE EMITTING`
   - How many times you see `🟡 PERSISTENT MANAGER RECEIVED`
   - How many times you see `🔴 _addReceivedMessage CALLED`
   - The stack traces from each `🔴` call
   - Whether the second call shows "DUPLICATE" or "NEW MESSAGE"

This will tell us EXACTLY where the duplication happens!
