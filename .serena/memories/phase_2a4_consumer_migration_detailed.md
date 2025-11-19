# Phase 2A.4: BLEService Consumer Migration - Detailed Plan

## Overview
Migrate 9 consumer files from BLEService to new sub-services architecture.
- Current state: All consumers import `ble_service.dart` directly
- Target state: Consumers import specific sub-services from `ble_service_facade.dart`
- Impact: Low (facade provides backward compatibility during transition)
- Time estimate: 8-10 hours for all migrations

## Consumer Files Analysis

### 1. lib/presentation/providers/ble_providers.dart ⚠️ HIGH IMPACT
**Why HIGH**: Core provider file, used by 6+ screens, defines 40+ providers
**Current usage**: 
- `BLEService bleService = BLEService();` (singleton)
- Uses: Connection, Discovery, Messaging, State

**Required changes**:
```dart
// Before: Single BLEService instance
final bleService = ref.watch(bleServiceProvider);

// After: BLEServiceFacade (acts as delegator)
final bleService = ref.watch(bleServiceProvider); // SAME - facade is drop-in replacement
```

**Sub-services accessed**:
- `bleService.connectionInfo` → BLEConnectionService
- `bleService.discoveredDevices` → BLEDiscoveryService  
- `bleService.receivedMessages` → BLEMessagingService
- `bleService.spyModeDetected` → BLEHandshakeService

**Migration approach**: NO CHANGES NEEDED if using facade
- BLEServiceFacade delegates all methods to sub-services
- Providers continue to work as-is
- Facade initialization happens once in AppCore

**Risk**: LOW - Facade provides 100% backward compatibility

---

### 2. lib/domain/services/mesh_networking_service.dart ⚠️ HIGH IMPACT
**Why HIGH**: Core mesh relay orchestration, controls relay logic, processes messages
**Current usage**:
- `BLEService _bleService;`
- Uses: Message sending, relay decisions, topology

**Required changes**:
- Continue using BLEService (or BLEServiceFacade)
- May want to import BLEMessagingService directly for clarity
- NO BREAKING CHANGES needed

**Methods used**:
- `sendMessage()` → BLEMessagingService
- `receivedMessages` stream → BLEMessagingService
- Connection state checking → BLEConnectionService

**Migration approach**: OPTIONAL
1. Keep using bleService through facade (simplest, no changes)
2. Or inject BLEMessagingService directly (more explicit)

**Recommendation**: Option 1 (keep using facade) - mesh networking is stable

**Risk**: LOW - Facade provides all required methods

---

### 3. lib/core/messaging/message_router.dart ⚠️ MEDIUM IMPACT
**Why MEDIUM**: Routes incoming messages, validates context
**Current usage**:
- `BLEService _bleService;`
- Uses: Current connection state, identity info

**Methods used**:
- `currentSessionId` (getter) → BLEConnectionService
- `otherUserName` (getter) → BLEConnectionService
- State validation → BLEStateManager (via facade)

**Required changes**: MINIMAL
- No method signature changes
- All required getters available through facade

**Risk**: LOW

---

### 4. lib/core/scanning/burst_scanning_controller.dart ⚠️ MEDIUM IMPACT
**Why MEDIUM**: Controls adaptive scanning, power management
**Current usage**:
- `BLEService _bleService;`
- Uses: Scanning control, state monitoring

**Methods used**:
- `startScanning()` → BLEDiscoveryService
- `stopScanning()` → BLEDiscoveryService
- `state` (getter) → BLEStateManager

**Required changes**: MINIMAL
- May import BLEDiscoveryService directly for clarity
- Or keep using facade (simpler)

**Risk**: LOW

---

### 5. lib/presentation/screens/home_screen.dart ⚠️ HIGH IMPACT (UI)
**Why HIGH**: Home screen UI, shows connection state, user interactions
**Current usage**:
- BLEService injected via provider
- Uses: Connection state, user names, peripheral mode

**Methods/properties accessed**:
- `isConnected` → BLEConnectionService
- `otherUserName` → BLEStateManager
- `isPeripheralMode` → BLEConnectionService
- `connectedDevice` → BLEConnectionService

**Required changes**: NONE if using facade
- All properties still available
- UI rendering unchanged

**Risk**: LOW - All properties present in facade

---

### 6. lib/presentation/widgets/discovery_overlay.dart ⚠️ HIGH IMPACT (UI)
**Why HIGH**: Device discovery UI, scanning control, user interactions
**Current usage**:
- `BLEService bleService = BLEService();`
- Uses: Device scanning, discovery state

**Methods used**:
- `startScanning()` → BLEDiscoveryService
- `stopScanning()` → BLEDiscoveryService
- `discoveredDevices` stream → BLEDiscoveryService
- `connectToDevice()` → BLEConnectionService
- `isConnected` → BLEConnectionService

**Required changes**: POSSIBLE OPTIMIZATION
- Could import BLEDiscoveryService + BLEConnectionService directly
- Or keep using facade (simpler)

**Risk**: LOW

---

### 7. lib/core/routing/network_topology_analyzer.dart 🟢 LOW IMPACT
**Why LOW**: Analyzes network topology, estimates network size
**Current usage**:
- `BLEService _bleService;`
- Uses: Connection info, device counts

**Methods used**:
- `discoveredDevices` stream → BLEDiscoveryService
- `connectedDevice` → BLEConnectionService

**Required changes**: MINIMAL
- Could use BLEDiscoveryService directly
- Or keep using facade

**Risk**: LOW - Simple accessor usage

---

### 8. lib/core/routing/connection_quality_monitor.dart 🟢 LOW IMPACT
**Why LOW**: Monitors connection quality, emits metrics
**Current usage**:
- `BLEService _bleService;`
- Uses: Connection state, RSSI

**Methods used**:
- `connectedDevice` → BLEConnectionService
- `connectionInfo` stream → BLEConnectionService

**Required changes**: MINIMAL

**Risk**: LOW

---

### 9. lib/domain/services/security_state_computer.dart 🟢 LOW IMPACT
**Why LOW**: Computes security state, doesn't modify BLE state
**Current usage**:
- `BLEService _bleService;`
- Uses: Identity info, pairing status

**Methods used**:
- `otherUserName` → BLEStateManager
- `myUserName` → BLEStateManager
- `theirPersistentKey` → BLEStateManager

**Required changes**: MINIMAL

**Risk**: LOW

---

## Migration Strategy

### Phase 2A.4.1: IMMEDIATE (No Changes, Validation Only)
**Time: 1-2 hours**

All consumers can continue using `BLEService` without changes because:
1. BLEServiceFacade IS BLEService (drop-in replacement)
2. All public methods/properties delegated
3. Facade handles sub-service coordination
4. No breaking changes in the contract

**Action**: 
- Run `flutter analyze` on all consumers → should show 0 errors
- Run `flutter test` → all tests should pass
- No actual code changes needed yet

### Phase 2A.4.2: OPTIONAL (Gradual Optimization)
**Time: 4-6 hours, spread over time**

For files that heavily use one sub-service, import directly for clarity:
1. `mesh_networking_service.dart` → import BLEMessagingService
2. `discovery_overlay.dart` → import BLEDiscoveryService
3. `burst_scanning_controller.dart` → import BLEDiscoveryService
4. Others: optional refactoring

### Phase 2A.4.3: TEST COVERAGE
**Time: 2-3 hours**

1. Unit tests: Already exist, should pass as-is
2. Integration tests: Update mocks if using fake_ble_service.dart
3. Real device tests: Critical paths on actual BLE hardware

---

## Risk Assessment

| File | Risk | Mitigation |
|------|------|-----------|
| ble_providers.dart | LOW | Facade delegates all providers |
| mesh_networking_service.dart | LOW | Mesh logic unchanged, facade provides methods |
| message_router.dart | LOW | All getters available through facade |
| discovery_overlay.dart | LOW | All discovery methods in facade |
| home_screen.dart | LOW | UI only accesses getters, no changes |
| burst_scanning_controller.dart | LOW | Facade provides scanning control |
| network_topology_analyzer.dart | LOW | Simple stream/getter access |
| connection_quality_monitor.dart | LOW | Simple stream access |
| security_state_computer.dart | LOW | Identity info via facade |

**Overall Risk**: ✅ VERY LOW - Facade ensures backward compatibility

---

## Test Plan

### Unit Tests
```bash
flutter test test/services/ --reporter=compact
```
Expected: All existing tests pass (no changes to consumer code)

### Integration Tests  
```bash
flutter test test/integration/ --reporter=compact
```
Expected: All integration paths work through facade

### Real Device Tests
Critical paths:
1. **Discovery**: Scan, find device, connect
2. **Handshake**: 4-phase protocol completion
3. **Messaging**: Send/receive encrypted messages
4. **Mesh Relay**: Forward message through peer
5. **Peripheral**: Act as server, accept central connection

---

## Timeline

| Phase | Task | Time | Status |
|-------|------|------|--------|
| 2A.4.0 | SpyModeInfo circular dep fix | 30 min | ✅ DONE |
| 2A.4.1 | Validation (no code changes) | 1-2 hrs | ⏳ PENDING |
| 2A.4.2a | ble_providers.dart review | 30 min | ⏳ PENDING |
| 2A.4.2b | mesh_networking_service.dart review | 30 min | ⏳ PENDING |
| 2A.4.2c | Other files review | 1 hr | ⏳ PENDING |
| 2A.4.3 | Test suite execution | 2-3 hrs | ⏳ PENDING |
| 2A.4.4 | Real device testing | 2-3 hrs | ⏳ PENDING |
| **TOTAL** | | 8-10 hrs | |

---

## Success Criteria

✅ All 9 consumer files compile without errors
✅ All 1,000+ unit tests pass
✅ All integration tests pass
✅ Real device BLE testing successful (all critical paths)
✅ No breaking changes in public API
✅ Facade properly delegates all 80+ methods
✅ SpyModeInfo circular dependency resolved

---

## Key Takeaway

**NO CONSUMER CODE CHANGES NEEDED** for Phase 2A.4.1!

The facade pattern provides 100% backward compatibility. All consumers can continue using BLEService as-is. The 5 sub-services work transparently behind the facade.

Later optimizations (Phase 2A.4.2) can selectively import sub-services for:
- Code clarity (explicit dependencies)
- Performance (fewer method indirections, though negligible)
- Type safety (more specific types instead of general facade)

But these are OPTIONAL - not required for functionality.
