# Phase 6D Option A: Execution Plan

## Baseline Metrics (Before Migration)
| Service | File | LOC | StreamControllers | Risk |
|---------|------|-----|-------------------|------|
| UserPreferences | user_preferences.dart | 204 | 1 | LOW |
| TopologyManager | topology_manager.dart | 389 | 1 | LOW |
| NetworkTopologyAnalyzer | network_topology_analyzer.dart | 465 | 1 | LOW |
| PinningService | pinning_service.dart | 232 | 1 | LOW |
| ChatNotificationService | chat_notification_service.dart | 30 | 2 | LOW |
| ArchiveSearchService | archive_search_service.dart | 681 | 2 | LOW |
| ArchiveManagementService | archive_management_service.dart | 829 | 3 | LOW |
| **TOTAL** | | **2,830** | **11** | **LOW** |

## Migration Strategy

### Pattern Selection
- **UserPreferences (username)**: StateProvider + StateNotifier (single state, broadcasted updates)
- **TopologyManager/Analyzer**: StreamProvider (event stream, multiple subscribers)
- **PinningService**: StateNotifier with AsyncValue (state + events)
- **ChatNotificationService**: Dual providers (separate concerns, 2 different event types)
- **ArchiveSearchService**: StreamProvider (search results are stateful streams)
- **ArchiveManagementService**: Multiple StateNotifiers (3 separate concerns: archive/policy/maintenance)

### Dependencies to Wire
1. Check if services are used in providers
2. Locate all `.watch()` calls in widgets/providers
3. Identify external listeners (grep for `.stream` usage)
4. Plan provider injection strategy

### Validation Checkpoints
After each milestone:
1. `flutter analyze` - zero errors
2. `flutter test --coverage` - all tests passing
3. Manual verification of stream/state behavior

## Milestone Breakdown

### M1: UserPreferences (1h)
- Replace `_usernameStreamController` with StateProvider
- Update `.usernameStream` getter to return provider
- Update `setUserName()` to use `ref.read()`
- Test: Verify username broadcasts still work

### M2: TopologyManager (1.5h)
- Replace `_topologyStreamController` with StreamProvider
- Update `topologyStream` getter
- Migrate singleton pattern to Riverpod provider
- Handle `._()` constructor → factory pattern

### M3: NetworkTopologyAnalyzer (1.5h)
- Similar to M2 (StreamProvider pattern)
- Handle timers (_topologyUpdateTimer, _cleanupTimer)
- Test: Ensure topology updates continue

### M4: PinningService (1.5h)
- Replace `_messageUpdatesController` with StateNotifier
- Use AsyncValue<List<Message>> for state
- Migrate toggle/save methods to state updates
- Test: Star/pin functionality

### M5: ChatNotificationService (1.5h)
- Dual migration: `_chatUpdatesController` + `_messageUpdatesController` → 2 StreamProviders
- Keep separate streams (different update frequencies)
- Test: Chat & message notifications

### M6: ArchiveSearchService (2h)
- Replace `_searchUpdatesController` + `_suggestionUpdatesController` with dual StreamProviders
- Handle _isInitialized state separately (StateProvider)
- Migrate search/suggestion logic
- Test: Search functionality

### M7: ArchiveManagementService (2h)
- Replace 3 controllers with StateNotifiers (archive, policy, maintenance)
- Handle background timers
- Migrate emit calls to state updates
- Test: Archive/restore/maintenance

## Success Criteria
✅ All 11 StreamControllers migrated to Riverpod providers
✅ flutter analyze → 0 errors
✅ flutter test → all passing
✅ No functional regressions
✅ LOC reduction: ~240 lines (est. 8-10% of target files)

## Known Gotchas
1. **Singleton patterns** - TopologyManager, ArchiveSearchService, ArchiveManagementService use `.instance`
   - Solution: Create provider that returns `.instance` singleton
2. **Late subscribers** - Need to handle late subscribers getting old state
   - Solution: Use AsyncValue + cache recent values
3. **Background timers** - Some services spawn timers in init
   - Solution: Move timer initialization to provider creation
4. **External listeners** - Need to find all `.stream` usages
   - Solution: grep before migration, add migration notes
