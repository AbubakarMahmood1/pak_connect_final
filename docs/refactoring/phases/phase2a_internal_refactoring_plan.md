# BLEService Internal Refactoring Plan
**Date**: 2025-11-14
**Branch**: claude/phase2a-ble-split-011CUxqckFVErTpkxxBd37x2
**Strategy**: Internal reorganization before extraction

---

## Current Structure Analysis

**Total Lines**: 3,431
**Public Methods**: ~78
**Current Organization**: Somewhat ad-hoc, some sections marked

---

## Proposed Internal Structure

### Section 1: Class Definition & Dependencies (Lines 1-150)
- Imports
- Class declaration
- Field declarations
- Dependency injection points
- Stream controllers

**NO CHANGES** - Keep as-is

---

### Section 2: Getters & Properties (Lines 150-250)
- Stream getters
- State getters (delegated)
- Bluetooth state monitoring getters

**CHANGE**: Add clear region marker
```dart
// ═══════════════════════════════════════════════════════════════
// SECTION: Public Getters & Properties
// ═══════════════════════════════════════════════════════════════
```

---

### Section 3: Initialization & Lifecycle (Lines 250-850)
**Methods**:
- `initialize()` (line 266)
- `dispose()` (line 3397)
- Event listener setup
- Manager initialization

**CHANGE**: Group together, add region marker
```dart
// ═══════════════════════════════════════════════════════════════
// SECTION: Initialization & Lifecycle
// Responsibilities: Service startup, shutdown, event wiring
// ═══════════════════════════════════════════════════════════════
```

---

### Section 4: Discovery Operations (Currently scattered)
**Methods to group**:
- `startScanning()` (line 2160)
- `stopScanning()` (line 2262)
- `startScanningWithValidation()` (line 3314)
- `_handleDiscoveredPeripheral()` (find in file)
- Discovery event listeners

**CHANGE**: Move together, add region marker
```dart
// ═══════════════════════════════════════════════════════════════
// SECTION: Discovery Operations (→ Future: BLEDiscoveryService)
// Responsibilities: BLE scanning, device deduplication, discovery events
// Interface: IBLEDiscoveryService
// ═══════════════════════════════════════════════════════════════
```

---

### Section 5: Advertising Operations (Currently scattered)
**Methods to group**:
- `startAsPeripheral()` (line 1979)
- `startAsPeripheralWithValidation()` (line 3349)
- `refreshAdvertising()` (line 2068)
- `_authoritativeAdvertisingState` getter (line 848)
- Advertising manager delegation

**CHANGE**: Move together, add region marker
```dart
// ═══════════════════════════════════════════════════════════════
// SECTION: Advertising Operations (→ Future: BLEAdvertisingService)
// Responsibilities: Peripheral mode, advertising, GATT server setup
// Interface: IBLEAdvertisingService (to be created)
// ═══════════════════════════════════════════════════════════════
```

---

### Section 6: Connection Management (Currently scattered)
**Methods to group**:
- `connectToDevice()` (line 2286)
- `disconnect()` (line 3076)
- `startAsCentral()` (line 2107)
- `startConnectionMonitoring()` (line 3070)
- `stopConnectionMonitoring()` (line 3072)
- Connection state handlers

**CHANGE**: Move together, add region marker
```dart
// ═══════════════════════════════════════════════════════════════
// SECTION: Connection Management (→ Future: BLEConnectionService)
// Responsibilities: Central/peripheral connections, MTU, lifecycle
// Interface: IBLEConnectionService (to be created)
// ═══════════════════════════════════════════════════════════════
```

---

### Section 7: Handshake Protocol (Currently scattered)
**Methods to group**:
- `requestIdentityExchange()` (line 2345)
- `triggerIdentityReExchange()` (line 2357)
- `_sendPeripheralIdentityExchange()` (line 2384)
- `_performHandshake()` (line 2466)
- `_sendHandshakeMessage()` (line 2618)
- `_onHandshakeComplete()` (line 2631)
- `_sendIdentityExchange()` (line 3014)
- `attemptIdentityRecovery()` (line 3120)
- Handshake coordinator integration

**CHANGE**: Move together, add region marker
```dart
// ═══════════════════════════════════════════════════════════════
// SECTION: Handshake Protocol (→ Future: BLEHandshakeService)
// Responsibilities: 4-phase handshake, identity exchange, Noise setup
// Interface: IBLEHandshakeService (to be created)
// CRITICAL: Contains FIX-008 retry logic - DO NOT MODIFY BEHAVIOR
// ═══════════════════════════════════════════════════════════════
```

---

### Section 8: Messaging Operations (Currently scattered)
**Methods to group**:
- `sendMessage()` (line 2789)
- `sendPeripheralMessage()` (line 2836)
- `sendQueueSyncMessage()` (line 259)
- `_sendProtocolMessage()` (line 2918)
- `_handleReceivedData()` (line 1491)
- `_processMessage()` (line 1837)
- `_processWriteQueue()` (line 2999)
- Message fragmentation handling

**CHANGE**: Move together, add region marker
```dart
// ═══════════════════════════════════════════════════════════════
// SECTION: Messaging Operations (→ Future: BLEMessagingService)
// Responsibilities: Message send/receive, fragmentation, ACKs, queue sync
// Interface: IBLEMessagingService (to be created)
// ═══════════════════════════════════════════════════════════════
```

---

### Section 9: Helper Methods & Utilities
**Methods**:
- `_updateConnectionInfo()` (line ~859)
- `_handleMutualConsentRequired()` (line 826)
- `_handleAsymmetricContact()` (line 836)
- Other private helpers

**CHANGE**: Add region marker
```dart
// ═══════════════════════════════════════════════════════════════
// SECTION: Helper Methods & Internal Utilities
// Responsibilities: Shared helpers, state updates, event handlers
// ═══════════════════════════════════════════════════════════════
```

---

## Implementation Strategy

### Phase 1: Add Region Markers (Low Risk)
**Steps**:
1. Insert section comments at current locations
2. NO method movement yet
3. Just visual organization
4. Test: `flutter analyze` should pass

**Commit**: "refactor(phase2a): Add section markers to BLEService"

---

### Phase 2: Move Methods Within File (Medium Risk)
**Steps**:
1. Move discovery methods together
2. Move advertising methods together
3. Move messaging methods together
4. Move connection methods together
5. Move handshake methods together
6. Each move = separate commit

**Test after EACH move**:
- `flutter analyze`
- `flutter test`
- Real device test (if method is in critical path)

**Rollback if**: Any test fails

---

### Phase 3: Extract Helper Classes (Low-Medium Risk)
**Candidates**:
- `_BufferedMessage` (already a helper class)
- Discovery deduplication logic
- Connection info update logic

**Optional**: May defer to future PR

---

## Risk Mitigation

### Pre-Checks
- [ ] All tests passing before starting
- [ ] Safety tag created (v1.2-pre-phase2a) ✅
- [ ] Branch pushed to remote ✅

### During Refactoring
- [ ] Add region markers first (visual only)
- [ ] Move methods one section at a time
- [ ] Commit after each section
- [ ] Test after each commit
- [ ] Stop if any test fails

### Rollback Plan
```bash
# If something breaks
git reset --hard v1.2-pre-phase2a
# Or revert specific commit
git revert <commit-hash>
```

---

## Success Metrics

**After Phase 1** (Region Markers):
- [ ] `flutter analyze`: 0 errors
- [ ] All existing tests pass
- [ ] File structure visually clearer
- [ ] NO behavioral changes

**After Phase 2** (Method Movement):
- [ ] `flutter analyze`: 0 errors
- [ ] All existing tests pass
- [ ] Methods grouped by responsibility
- [ ] Clear boundaries for future extraction
- [ ] Real device test passes (scan → connect → message)

---

## Timeline

**Phase 1** (Region Markers): 30 minutes
**Phase 2** (Method Movement): 2-3 hours (one section at a time)
**Total**: 3-4 hours + testing time

---

## Next Steps

1. ✅ Create this plan document
2. ⏳ Implement Phase 1 (region markers)
3. ⏳ Commit and push for user testing
4. ⏳ If Phase 1 passes, proceed to Phase 2
5. ⏳ If any step fails, rollback and reassess

---

**Status**: READY TO EXECUTE PHASE 1
**Current Location**: `claude/phase2a-ble-split-011CUxqckFVErTpkxxBd37x2`
