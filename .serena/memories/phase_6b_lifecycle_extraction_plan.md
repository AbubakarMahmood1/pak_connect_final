# Phase 6B: Lifecycle Extraction Plan

## Objective
Extract lifecycle setup orchestration from ChatScreenController to ChatSessionViewModel/Lifecycle, reducing Controller complexity and centralizing setup logic.

## Current State
- **ChatScreenController.initialize()** (lines 461-474): Orchestrates 6 setup calls
- **Setup methods scattered**: _setupMeshNetworking(), _setupDeliveryListener(), _checkAndSetupLiveMessaging(), _setupPersistentChatManager(), _setupSecurityStateListener()
- **Message listener logic**: _activateMessageListener() manages state and delegates to lifecycle
- **Buffer management**: _processBufferedMessages() calls lifecycle.processBufferedMessages()

## Extraction Targets

### M2: Setup Orchestration Extraction (PRIORITY 1)
Move initialization sequencing from Controller to ViewModel:

**FROM ChatScreenController.initialize():**
```
1. await _logChatOpenState();
2. await _loadMessages();
3. _setupPersistentChatManager();
4. _checkAndSetupLiveMessaging();
5. _setupMeshNetworking();
6. _setupDeliveryListener();
7. _sessionLifecycle.ensureRetryCoordinator();
8. _setupSecurityStateListener();
```

**TO ChatSessionViewModel method:**
```
Future<void> initializeLifecycle() async {
  // Call lifecycle setup methods in proper sequence
  // Move _checkAndSetupLiveMessaging logic
  // Move _setupMeshNetworking logic
  // etc...
}
```

### M3: Message Listener Activation Extraction (PRIORITY 2)
Move `_activateMessageListener()` logic to ViewModel/Lifecycle

**Current location**: ChatScreenController lines 769-798
- Manages messageListenerActive state
- Calls lifecycle.registerPersistentListener()
- Calls lifecycle.attachMessageStream()
- Adds to messageBuffer and calls _processBufferedMessages()

**Extract to**: ChatSessionViewModel or ChatSessionLifecycle
- Create lifecycle method: activateMessageListener()
- Encapsulate buffer management

### M4: Wire Lifecycle Callbacks
Add callback dependencies to ViewModel for:
- connectionInfoProvider access
- meshNetworkStatusProvider access
- connectionServiceProvider access
- persistentChatStateManagerProvider access
- securityStateProvider invalidation

## Extraction Impact

### Files Modified
1. `lib/presentation/viewmodels/chat_session_view_model.dart` (add lifecycle initialization)
2. `lib/presentation/controllers/chat_session_lifecycle.dart` (enhance with orchestration helpers)
3. `lib/presentation/controllers/chat_screen_controller.dart` (thin down initialize())

### Metrics Targets
- Controller: 1,037 → 850 LOC (-187, ~18% reduction)
- ViewModel: 361 → 500+ LOC (+140 for lifecycle setup)
- Lifecycle: Keep as-is (already has methods, just needs orchestration)

### Compilation Status
- 0 new errors expected
- 5 pre-existing warnings remain

## Implementation Order
1. M2: Add initializeLifecycle() to ViewModel with setup sequencing
2. M2: Add callback dependencies to ViewModel constructor
3. M3: Extract _activateMessageListener() logic
4. M4: Wire callbacks and validate
5. M5: Run tests and commit

## Key Assumptions
- ChatSessionLifecycle.initialize() already exists (need to check)
- Setup methods in Lifecycle are mature (handleMeshStatus, setupDeliveryListener, etc.)
- Message buffer management is safe to move to ViewModel
- No circular dependencies with callback pattern
