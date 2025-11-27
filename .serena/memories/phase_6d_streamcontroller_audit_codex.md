# Phase 6D: StreamController Consolidation - Codex Audit Report

## Executive Summary
- **Total StreamControllers:** 40 across 19 files
- **Total LOC Savings:** ~800 LOC (67% reduction)  
- **Estimated Time:** 28-34 hours total
- **Risk Distribution:** 30% LOW, 45% MEDIUM, 25% HIGH

## Quick Wins (Phase 1) - Recommended Start
**Time:** 6-8 hours
**Controllers:** 12
**LOC Saved:** ~240
**Risk:** All LOW

### Phase 1 Targets:
1. UserPreferences username - 1h
2. TopologyManager - 1.5h
3. NetworkTopologyAnalyzer - 1.5h
4. PinningService - 1.5h
5. ChatNotificationService (2) - 1.5h
6. ArchiveSearchService (2) - 2h
7. ArchiveManagementService (3) - 2h

## Medium Complexity (Phase 2)
**Time:** 12-14 hours
**Controllers:** 18
**LOC Saved:** ~360
**Risk:** MEDIUM

Includes: ChatListCoordinator, ChatConnectionManager, BluetoothStateMonitor, BurstScanningController, MeshNetworkHealthMonitor, etc.

## High Complexity (Phase 3)
**Time:** 10-12 hours
**Controllers:** 10
**LOC Saved:** ~200
**Risk:** HIGH

Critical: AppCore (global lifecycle), BLEServiceFacade (core BLE stack with 5 controllers)

## Key Gotchas
1. **Singleton StreamControllers** - Must use `.instance` pattern
2. **Late-Subscriber Delivery** - Use StateNotifier with AsyncValue
3. **onListen/onCancel Callbacks** - Move to StateNotifier lifecycle
4. **External Listeners** - Global search needed to find all consumers

## Migration Patterns
- Event Stream → StreamProvider
- State Broadcast → StateProvider/StateNotifier  
- Computed State → Provider
- Late-Subscriber → StateNotifier with AsyncValue

## Top 3 Consolidation Opportunities
1. **BLEServiceFacade** - 5 controllers → 1 unified BLE event stream (60 LOC saved)
2. **ArchiveService** - 3 controllers → 1 event bus (40 LOC saved)
3. **MeshNetworkHealthMonitor** - 4 controllers → 2 providers (80 LOC saved)

## Recommended Execution
1. Start with Phase 1 (Quick Wins) - Build confidence
2. Then Phase 2 (Medium) - Tackle most controllers
3. Finally Phase 3 (High Risk) - Core infrastructure last

See full Codex report for:
- Detailed code examples (before/after)
- Complete migration checklist
- File-by-file breakdown
- Risk assessment for each controller
