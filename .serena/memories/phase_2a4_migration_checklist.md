# Phase 2A.4: Consumer Migration Checklist & Implementation Guide

## Overview
This document provides a step-by-step guide for migrating 16+ consumer files from using `BLEService` to using `BLEServiceFacade`.

## Priority Order

### TIER 1: CRITICAL (UI & State Management) - Day 1
These files MUST be updated first as they're entry points for the entire UI layer.

#### 1. `lib/presentation/providers/ble_providers.dart` 
**Status**: Not yet updated
**Complexity**: Medium
**Effort**: 1 hour
**Impact**: All UI access to BLE state

**Changes needed**:
```dart
// Line 5: Update import
- import '../../data/services/ble_service.dart';
+ import '../../data/services/ble_service_facade.dart';

// Line 61: Update type signature
- BLEService bleService,
+ IBLEServiceFacade bleService,

// Line 119-120: Update provider definition
- final bleServiceProvider = Provider<BLEService>((ref) {
-   final service = BLEService();
+ final bleServiceProvider = Provider<IBLEServiceFacade>((ref) {
+   final service = BLEServiceFacade();

// All other type annotations that reference BLEService
- BLEService bleService
+ IBLEServiceFacade bleService
```

**Verification**:
```bash
flutter pub get
flutter analyze lib/presentation/providers/ble_providers.dart
# Should have 0 errors
```

#### 2. `lib/core/scanning/burst_scanning_controller.dart`
**Status**: Not yet updated
**Complexity**: Medium
**Effort**: 1 hour
**Impact**: Adaptive scanning, power management

**Changes needed**:
```dart
// Update import
- import '../../../data/services/ble_service.dart';
+ import '../../../data/services/ble_service_facade.dart';

// Update type
- BLEService _bleService;
+ IBLEServiceFacade _bleService;
```

**API compatibility check**:
- `bleService.startScanning()` → `facade.startScanning()` ✓
- `bleService.stopScanning()` → `facade.stopScanning()` ✓
- `bleService.isConnected` → `facade.isConnected` ✓
- `bleService.bluetoothStateStream` → `facade.bluetoothStateStream` ✓

#### 3. `lib/domain/services/mesh_networking_service.dart`
**Status**: Not yet updated
**Complexity**: High
**Effort**: 1.5 hours
**Impact**: Mesh relay, network routing

**Changes needed**:
```dart
// Update import
- import '../../data/services/ble_service.dart';
+ import '../../data/services/ble_service_facade.dart';

// Update constructor parameter
- final BLEService _bleService;
+ final IBLEServiceFacade _bleService;

// Update method calls:
- _bleService.sendMessage()  → _bleService.sendMessage() ✓
- _bleService.registerQueueSyncMessageHandler() → facade method ✓
```

**Critical APIs to verify**:
- `facade.sendMessage()` - exists ✓
- `facade.receivedMessagesStream` - exists ✓
- `facade.registerQueueSyncMessageHandler()` - exists ✓
- `facade.stateManager` - accessible via sub-services ✓

### TIER 2: HIGH PRIORITY (Core Services) - Day 2
These handle critical business logic and need careful migration.

#### 4. `lib/core/messaging/message_router.dart`
**Complexity**: High
**Effort**: 1.5 hours
**Migration notes**: Routes messages between local/relay/encryption

#### 5. `lib/domain/services/security_state_computer.dart`
**Complexity**: Medium
**Effort**: 1 hour
**Migration notes**: Computes security levels based on connection state

#### 6. `lib/core/routing/network_topology_analyzer.dart`
**Complexity**: Medium
**Effort**: 1 hour
**Migration notes**: Analyzes mesh topology for routing decisions

#### 7. `lib/core/routing/connection_quality_monitor.dart`
**Complexity**: Low
**Effort**: 45 minutes
**Migration notes**: Monitors connection health metrics

#### 8. `lib/core/discovery/device_deduplication_manager.dart`
**Complexity**: Medium
**Effort**: 1 hour
**Migration notes**: Deduplicates discovered devices

### TIER 3: MEDIUM PRIORITY (UI Screens & Widgets) - Day 3
These are UI components that can be migrated in parallel.

#### 9. `lib/presentation/screens/home_screen.dart`
**Complexity**: Low
**Effort**: 30 minutes

#### 10. `lib/presentation/widgets/discovery_overlay.dart`
**Complexity**: Low
**Effort**: 30 minutes

#### 11. Other consumers in `lib/presentation/` (various screens/widgets)
**Complexity**: Low
**Effort**: 1 hour total
**Files**: Check grep output for all references

## Migration Checklist Template

For each file being migrated, use this checklist:

```
File: ___________________________________________
Priority: TIER 1 / 2 / 3
Estimated Effort: ___ hours
Actual Effort: ___ hours
Date Started: __________
Date Completed: __________

STEPS:
☐ 1. Identify all BLEService imports and usages
   Imports found: ___________
   Usages found: ___________
   
☐ 2. Update import statements
   Old: import '...ble_service.dart'
   New: import '...ble_service_facade.dart' or interface
   
☐ 3. Update type annotations
   OLD types: ___________
   NEW types: ___________
   
☐ 4. Verify API compatibility
   Methods called:
   ☐ Method1 - compatible: YES/NO/UNKNOWN
   ☐ Method2 - compatible: YES/NO/UNKNOWN
   ☐ MethodN - compatible: YES/NO/UNKNOWN
   
☐ 5. Check stream/future signatures
   ☐ Return types match
   ☐ Parameter types match
   ☐ Callbacks compatible
   
☐ 6. Run compilation check
   Command: flutter analyze lib/path/to/file.dart
   Result: ☐ 0 errors ☐ N errors (list below)
   
☐ 7. Run tests (if applicable)
   Test file: ___________
   Result: ☐ ALL PASS ☐ X FAIL (list below)
   
☐ 8. Verify with git diff
   Changes look good: ☐ YES / ☐ NO
   Unexpected changes: ___________
   
☐ 9. Commit changes
   Commit message: ___________
   
NOTES:
___________________________________________________________________

ISSUES ENCOUNTERED:
___________________________________________________________________

RESOLUTION:
___________________________________________________________________
```

## API Compatibility Reference

### BLEServiceFacade Public API

#### Connection Methods
```dart
// Facade delegates to BLEConnectionService
Future<void> connectToDevice(Peripheral device)
Future<void> disconnect()
Future<ConnectionInfo?> getConnectionInfoWithFallback()
Future<bool> attemptIdentityRecovery()
```

#### Discovery Methods
```dart
// Facade delegates to BLEDiscoveryService
Future<void> startScanning({ScanningSource source = ScanningSource.manual})
Future<void> stopScanning()
Future<Peripheral?> scanForSpecificDevice({Duration? timeout})
Stream<List<Peripheral>> get discoveredDevicesStream
```

#### Advertising Methods
```dart
// Facade delegates to BLEAdvertisingService
Future<void> startAsPeripheral()
Future<void> refreshAdvertising({bool? showOnlineStatus})
Future<void> startAsCentral()
```

#### Messaging Methods
```dart
// Facade delegates to BLEMessagingService
Future<bool> sendMessage(String message, {...})
Future<bool> sendPeripheralMessage(String message, {...})
Stream<String> get receivedMessagesStream
```

#### Handshake Methods
```dart
// Facade delegates to BLEHandshakeService
Future<void> performHandshake({bool? startAsInitiatorOverride})
Future<void> sendIdentityExchange()
Future<void> sendPeripheralIdentityExchange()
Future<void> requestIdentityExchange()
Future<void> triggerIdentityReExchange()
Future<void> sendHandshakeMessage(ProtocolMessage message)
```

#### State Access
```dart
// Access to state manager
BLEStateManager get stateManager  // Via _getStateManager()

// Connection info
Stream<ConnectionInfo> get connectionInfoStream
ConnectionInfo get currentConnectionInfo

// Bluetooth state
Stream<BluetoothStateInfo> get bluetoothStateStream
Stream<BluetoothStatusMessage> get bluetoothMessageStream

// Properties
bool get isConnected
bool get isMonitoring
bool get isActivelyReconnecting
bool get isPeripheralMode
bool get isAdvertising
bool get isScanning
```

## Testing Strategy

### Unit Tests Per Consumer
After migrating each file, run relevant unit tests:

```bash
# Example for mesh networking service
flutter test test/domain/services/mesh_networking_service_test.dart

# Example for providers
flutter test test/presentation/providers/ble_providers_test.dart
```

### Integration Testing
After all TIER 1 migrations:
```bash
# Full app integration test
flutter test test/integration/ble_integration_test.dart

# Real device testing (manual)
flutter run --release
# Test all BLE flows:
# 1. Device discovery
# 2. Connection
# 3. Message sending/receiving
# 4. Handshake
# 5. Identity exchange
```

## Common Migration Patterns

### Pattern 1: Direct Method Calls
```dart
// BEFORE
final result = bleService.sendMessage("Hello");

// AFTER (identical API)
final result = facade.sendMessage("Hello");
```

### Pattern 2: Stream Subscription
```dart
// BEFORE
bleService.receivedMessagesStream.listen((message) {
  // handle message
});

// AFTER (identical API)
facade.receivedMessagesStream.listen((message) {
  // handle message
});
```

### Pattern 3: Property Access
```dart
// BEFORE
if (bleService.isConnected) {
  // do something
}

// AFTER (identical API)
if (facade.isConnected) {
  // do something
}
```

### Pattern 4: Callback Registration
```dart
// BEFORE
bleService.registerQueueSyncMessageHandler(handler);

// AFTER (identical API)
facade.registerQueueSyncMessageHandler(handler);
```

## Rollback Plan

If migration encounters blockers:

1. **Local rollback**: 
   ```bash
   git checkout lib/path/to/file.dart
   ```

2. **Revert entire tier**:
   ```bash
   git revert <commit-hash>
   ```

3. **Issue investigation**:
   - Check facade implementation for missing method
   - Verify return type compatibility
   - Review stream handling in sub-services

4. **Escalation**:
   - Document blocker in issue
   - Request code review from architecture team
   - Plan Phase 2B enhancements if needed

## Success Criteria

Phase 2A.4 migration is complete when:

- ✅ All 16+ consumer files use BLEServiceFacade
- ✅ flutter analyze reports 0 errors (except unrelated)
- ✅ flutter test runs all tests with > 85% pass rate
- ✅ Real device testing confirms all BLE flows work
- ✅ No regression in existing features
- ✅ Performance metrics unchanged or improved

## Timeline Estimate

```
TIER 1: 3-4 hours (1 day)
TIER 2: 6-7 hours (1-2 days)
TIER 3: 2-3 hours (1 day)
Testing & Fixes: 2-4 hours
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TOTAL: 13-18 hours (2-3 days)
```

## Notes

- All methods are drop-in replacements - no behavioral changes needed
- BLEServiceFacade is backward compatible with BLEService API
- Services are lazy-initialized on first access
- Testing with platform stubs sufficient for unit tests
- Real device testing required for integration validation
