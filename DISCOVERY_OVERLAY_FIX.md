# Discovery Overlay Connection Logic Fix

## Problem Description

The discovery overlay had flawed logic for handling device connection attempts. Specifically:

1. **First click**: Attempts to connect to discovered device
2. **Second click**: Should retry connection if failed, but instead opened a temporary chat

## Root Cause Analysis

The issue was in the `onTap` handler logic in `discovery_overlay.dart`:

```dart
onTap: () {
  final bleService = ref.read(bleServiceProvider);
  if (bleService.connectedDevice?.uuid == device.uuid) {
    // Open chat - this was being triggered incorrectly
    Navigator.push(...);
  } else {
    // Connect - this should allow retry
    _connectToDevice(device);
  }
}
```

### Problems:
1. **No connection attempt tracking**: The logic couldn't distinguish between "never attempted" and "previously failed"
2. **Race conditions**: Connection state could be inconsistent between BLE layer and UI
3. **No retry mechanism**: Failed connections had no clear retry path
4. **Poor UX**: Users couldn't tell what state the connection was in

## Solution Implemented

### 1. Added Connection Attempt State Tracking

```dart
enum ConnectionAttemptState {
  none,       // Never attempted
  connecting, // Currently connecting
  failed,     // Failed - can retry
  connected,  // Successfully connected
}

final Map<String, ConnectionAttemptState> _connectionAttempts = {};
```

### 2. Enhanced Connection Logic

The new `onTap` logic properly handles all states:

```dart
onTap: () {
  final bleService = ref.read(bleServiceProvider);
  final deviceId = device.uuid.toString();
  final attemptState = _connectionAttempts[deviceId] ?? ConnectionAttemptState.none;
  
  // Check actual BLE connection status first
  final isActuallyConnected = bleService.connectedDevice?.uuid == device.uuid;
  
  if (isActuallyConnected) {
    // Already connected - open chat
    widget.onClose();
    Navigator.push(context, MaterialPageRoute(
      builder: (context) => ChatScreen(device: device),
    ));
  } else if (attemptState == ConnectionAttemptState.connecting) {
    // Currently connecting - show message and ignore tap
    _showError('Connection in progress, please wait...');
  } else if (attemptState == ConnectionAttemptState.failed) {
    // Failed previously - offer retry
    _showRetryDialog(device);
  } else {
    // First attempt or no previous state - connect
    _connectToDevice(device);
  }
}
```

### 3. Visual Status Indicators

Added visual indicators to show connection state:

- **Blue "TAP TO CONNECT"**: Never attempted
- **Orange "CONNECTING"**: Connection in progress (with spinner)
- **Red "RETRY"**: Connection failed (with retry icon)
- **Green "CONNECTED"**: Successfully connected (with chat icon)

### 4. Retry Dialog

When user taps a failed connection, shows a confirmation dialog:
- "Connection Failed" message
- "Cancel" or "Retry" options
- Clear user action required

### 5. State Management

- Tracks connection attempts per device UUID
- Automatically cleans up stale device states
- Verifies actual BLE connection status vs UI state
- Prevents multiple simultaneous connection attempts to same device

## Benefits

1. **Clear UX**: Users can see connection status at a glance
2. **Proper retry**: Failed connections can be retried without confusion
3. **Prevents race conditions**: Checks actual BLE state vs cached state
4. **Better feedback**: Users know when connections are in progress
5. **State cleanup**: Old connection states are automatically cleaned up

## Testing Instructions

To test the fix:

1. **Open discovery overlay** from chats screen
2. **First tap on device**: Should show "CONNECTING" status with spinner
3. **While connecting**: Tapping again shows "Connection in progress" message
4. **If connection fails**: Status changes to "RETRY" with red color
5. **Tap failed device**: Shows retry dialog with Cancel/Retry options
6. **If connection succeeds**: Status shows "CONNECTED" with green color
7. **Tap connected device**: Opens chat screen immediately

## Files Modified

- `lib/presentation/widgets/discovery_overlay.dart`: Main logic fix

## Technical Details

The fix maintains backward compatibility while adding robust state tracking. The connection attempt tracking is kept in memory only (not persisted) since it's session-specific information.

The visual indicators use Material Design colors and icons to provide clear, accessible feedback to users about connection states.