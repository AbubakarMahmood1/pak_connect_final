# State Management (Riverpod 3.0)

## Provider Types

- **`AsyncNotifier`**: Complex state with mutation methods (e.g., `ContactsNotifier`)
- **`StreamProvider`**: Real-time data streams (e.g., `meshNetworkStatusProvider`)
- **`FutureProvider`**: Async one-time values (e.g., `contactsProvider`)
- **`Provider`**: Computed derived values (e.g., `bleServiceProvider`)

**Key Provider Files**:
- `lib/presentation/providers/ble_providers.dart`: BLE state, scanning control
- `lib/presentation/providers/mesh_networking_provider.dart`: Mesh status, relay stats
- `lib/presentation/providers/contact_provider.dart`: Contact management

**Pattern**: Use `ref.watch()` in widgets, `ref.read()` in callbacks.

## Phase 6: StreamController → Riverpod Migration Pattern

**Problem**: Manual `StreamController` management leads to memory leaks (uncancelled subscriptions), boilerplate, and lifecycle issues.

**Solution**: Bridge service StreamControllers through Riverpod `StreamProvider`, consume via `ref.listen` in Notifiers.

### Current Status (Phase 6 cleanup)
- BLE stack (connection/handshake/messaging/discovery/hints): listener sets + `Stream.multi`; no controllers.
- HomeScreen intent stream: listener set + `Stream.multi`; `_NullChatInteractionHandler` updated.
- PinningService: listener set + `Stream.multi`; emits on star/unstar, clears listeners on dispose.
- Archive providers: singleton services exposed via `StreamProvider`; no manual controllers in core code.

### When to Keep StreamControllers vs Migrate

**✅ KEEP StreamController** (expose via StreamProvider):
- **Hardware/Plugin events**: BLE state changes, connection events from platform channels
- **Multi-consumer event streams**: Events that multiple parts of the app need to observe
- **Service-owned streams**: When the service is the source of truth for event generation

**❌ MIGRATE to StateNotifier/AsyncNotifier**:
- **UI state**: Loading states, form validation, navigation state
- **Computed/derived state**: State calculated from other sources
- **Single-consumer state**: State only used by one screen/component

### Migration Pattern (3 Steps)

**Step 1: Expose Service Streams via StreamProvider**

```dart
// Before (manual subscription in consumer):
class MyNotifier extends Notifier<MyState> {
  late MyService _service;
  StreamSubscription? _subscription;

  @override
  MyState build() {
    _service = ref.watch(myServiceProvider);
    _subscription = _service.updates.listen((event) {
      state = state.copyWith(data: event);
    });
    ref.onDispose(() => _subscription?.cancel());
    return MyState.initial();
  }
}

// After (StreamProvider bridge):
// In provider file:
final myServiceUpdatesProvider = StreamProvider<MyUpdate>((ref) {
  final service = ref.watch(myServiceProvider);
  return service.updates; // Service still has StreamController internally
});
```

**Step 2: Consume via ref.listen in Notifier**

```dart
class MyNotifier extends Notifier<MyState> {
  @override
  MyState build() {
    // ✅ Automatic lifecycle management, no manual subscription cleanup
    ref.listen<AsyncValue<MyUpdate>>(
      myServiceUpdatesProvider,
      (prev, next) {
        next.whenData((value) {
          state = state.copyWith(data: value);
        });
      },
    );
    return MyState.initial();
  }
}
```

**Step 3: Use ref.read for Service Methods**

```dart
class MyNotifier extends Notifier<MyState> {
  Future<void> performAction() async {
    state = state.copyWith(loading: true);
    // ✅ No stored service reference, always fresh from provider
    final service = ref.read(myServiceProvider);
    await service.doSomething();
    state = state.copyWith(loading: false);
  }
}
```

### Benefits

- **✅ Automatic disposal**: Riverpod handles subscription cleanup
- **✅ Multi-consumer support**: StreamProvider fans out to multiple listeners
- **✅ Error handling**: `AsyncValue` provides built-in error states
- **✅ Late subscriber support**: StreamProviders handle late subscriptions correctly
- **✅ Testability**: Easy to mock providers vs manual stream injection

### Real Examples

**Example 1: Archive Management (Domain Service)**
- Service: `ArchiveManagementService` (singleton with 3 StreamControllers)
- Providers: `archiveUpdatesProvider`, `archivePolicyUpdatesProvider`, `archiveMaintenanceUpdatesProvider`
- Consumer: `ArchiveOperationsNotifier` uses `ref.listen` to handle archive events
- File: `lib/presentation/providers/archive_provider.dart:49-68`

**Example 2: Mesh Network Health (Core Service)**
- Service: `MeshNetworkHealthMonitor` (4 StreamControllers for mesh stats)
- Providers: `meshStatusStreamProvider`, `relayStatsStreamProvider`, `queueStatsStreamProvider`
- Consumer: `MeshRuntimeNotifier` uses `ref.listen` for each stream
- File: `lib/presentation/providers/mesh_networking_provider.dart:254-271`

### Anti-Patterns to Avoid

**❌ DON'T**: Store service references in Notifier fields
```dart
class BadNotifier extends Notifier<State> {
  late MyService _service; // ❌ Stale reference if provider updates

  @override
  State build() {
    _service = ref.watch(myServiceProvider); // ❌ Stored reference
    return State.initial();
  }

  void doSomething() {
    _service.doIt(); // ❌ May be stale
  }
}
```

**✅ DO**: Use ref.read for service access
```dart
class GoodNotifier extends Notifier<State> {
  @override
  State build() => State.initial();

  void doSomething() {
    final service = ref.read(myServiceProvider); // ✅ Always fresh
    service.doIt();
  }
}
```

**❌ DON'T**: Manually manage StreamSubscriptions
```dart
class BadNotifier extends Notifier<State> {
  final List<StreamSubscription> _subs = [];

  @override
  State build() {
    _subs.add(stream1.listen(...)); // ❌ Manual lifecycle
    _subs.add(stream2.listen(...));
    ref.onDispose(() {
      for (final sub in _subs) sub.cancel(); // ❌ Boilerplate
    });
    return State.initial();
  }
}
```

**✅ DO**: Use ref.listen (automatic cleanup)
```dart
class GoodNotifier extends Notifier<State> {
  @override
  State build() {
    ref.listen(stream1Provider, (prev, next) { ... }); // ✅ Auto cleanup
    ref.listen(stream2Provider, (prev, next) { ... }); // ✅ Auto cleanup
    return State.initial();
  }
}
```
