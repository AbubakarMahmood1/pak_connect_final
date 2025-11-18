# Phase 4E: HomeScreen Extraction - Codex Guidance + Execution Plan

## Codex Recommendation: Option B (3 Services)

### Why Option B Wins
1. **Chat loading already isolated** (lines 60-210)
   - `_loadChats()`, `_updateSingleChatItem()`, `_refreshUnreadCount()`
   - Periodic/global listeners clearly belong here

2. **Connection state is separate concern** (lines 934-975)
   - `_setupPeripheralConnectionListener()`, `_setupDiscoveryListener()`
   - `_determineConnectionStatus()`, `_isContactOnlineViaHash()`
   - Encapsulate BLE stream wiring WITHOUT repository coupling

3. **Clear reuse pattern**
   - ChatConnectionManager heuristics (hash matching, BLE state, last-seen) are testable in isolation
   - ChatListCoordinator consumes connection status via stream
   - No duplication, clean boundaries

4. **Inter-service dependencies stay minimal**
   - HomeScreen orchestrates, not services talking to each other
   - User actions emit intents → coordinator decides if list needs refresh
   - Preserves independence, keeps DI simple

5. **Testing ROI is better**
   - 55 tests vs 40 tests = worth the investment
   - Connection manager gets focused tests (hash matching, stream handling, status transitions)
   - These are the brittle UX-critical parts today

### Architecture Pattern (Matches 4A-4D)
```
HomeScreen (Widget - rendering only)
    ↓
HomeScreenFacade (DI + lazy init orchestration)
    ├── ChatListCoordinator (300 LOC)
    │   └─ Consumes: connectionStatusStream from ChatConnectionManager
    ├── ChatConnectionManager (200 LOC)
    │   └─ Exposes: connectionStatusStream
    └── ChatInteractionHandler (350 LOC)
        └─ Emits: intents/events
```

### Service Responsibilities (From Codex)

**ChatListCoordinator** (300 LOC)
- Load chats with search/filters
- Periodic refresh (10s timer)
- Global message listener (real-time updates)
- Surgical single chat update
- Unread count stream management
- **Consumes**: connectionStatusStream from ChatConnectionManager

**ChatConnectionManager** (200 LOC)
- BLE connection listener setup
- Discovery data listener setup
- Connection status determination (multipart heuristic)
  - Current active session check
  - Persistent key match (MEDIUM+ security)
  - Nearby device check via hash
  - Last seen timestamp check
- Hash matching logic (`_isContactOnlineViaHash`)
- **Exposes**: `Stream<ConnectionStatus>` or similar for status updates

**ChatInteractionHandler** (350 LOC)
- Navigation: openChat, openProfile, openContacts, openArchives
- Search UI: showSearch, clearSearch
- Display name editing
- Menu actions
- Archive/delete with confirmations
- Pin/unpin chats
- Context menu
- **Pattern**: Emit intents/events → HomeScreen/Facade decides next action

**HomeScreenFacade** (~200 LOC)
- Lazy init of 3 services
- Coordinate service calls (when user action → which service, when to refresh)
- Expose simple API for widget
- 100% backward compatible

### Implementation Sequence
1. Create 4 interfaces (IChatListCoordinator, IChatConnectionManager, IChatInteractionHandler, IHomeScreenFacade)
2. Extract ChatConnectionManager first (foundation, pure logic, testable)
3. Extract ChatListCoordinator (depends on connection manager stream)
4. Extract ChatInteractionHandler (simplest, no dependencies)
5. Create HomeScreenFacade (orchestrates all 3)
6. Update HomeScreen widget to use facade
7. Write 55+ unit tests (prioritize connection manager heuristics)

### Key Implementation Details
- ChatConnectionManager exposes a stream that ChatListCoordinator watches
- ChatInteractionHandler doesn't call ChatListCoordinator directly
- After action (archive/delete/pin), emit event → facade decides refresh
- Keep ALL rendering in HomeScreen widget (don't extract UI methods)
- Services focus on state/logic only

### Testing Strategy (55+ tests)
- ChatConnectionManager: 20+ tests
  - Hash matching logic (ephemeral, persistent, last-seen)
  - BLE stream handling
  - Status transitions
  - Edge cases (offline, connecting, nearby, recent)
- ChatListCoordinator: 18+ tests
  - Load chats with/without search
  - Periodic refresh mechanics
  - Global message listener updates
  - Surgical update vs full refresh
  - Unread count stream
- ChatInteractionHandler: 12+ tests
  - Navigation flows
  - Confirmation dialogs (archive/delete)
  - Context menu actions
- HomeScreenFacade: 5+ integration tests
  - Service initialization
  - Delegation verification

### Backward Compatibility
- HomeScreenFacade implements IHomeScreenFacade
- All existing imports/exports unchanged
- No consumer code changes needed (facade handles all)
- Migration is internal, widget interface stays same

---

## Status: Ready to Execute Phase 4E
- Codex validated Option B
- Architecture is clear
- Service boundaries defined
- Testing strategy confirmed
- Can start extraction immediately

Next: Define 4 interfaces, then extract services one by one.
