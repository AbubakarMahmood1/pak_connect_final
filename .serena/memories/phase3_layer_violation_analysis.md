# Phase 3: Layer Violation Fixes - Complete Analysis

## Executive Summary

**Status**: 2 weeks (Weeks 8-9 of 12-week plan)
**Scope**: Fix 17 layer violations across Core layer
**Risk**: Medium (architectural changes, but well-isolated)
**Test Coverage**: 20+ new tests

---

## Layer Violations Identified

### CRITICAL VIOLATIONS

**1. Core → Presentation (HIGHEST PRIORITY)**
- **File**: `lib/core/services/navigation_service.dart`
- **Issue**: Imports `presentation/screens/chat_screen.dart`, `presentation/screens/contacts_screen.dart`
- **Problem**: Core layer should NOT know about UI screens
- **Solution**: Remove screen imports, use route names + callbacks instead
- **Complexity**: LOW
- **Effort**: 2 hours

**2. Core → Data/Services (CRITICAL)**
- **Files**: 
  - `lib/core/messaging/message_router.dart` → imports `data/services/ble_service.dart`
  - `lib/core/messaging/mesh_relay_engine.dart` → imports `data/services/seen_message_store.dart`
- **Problem**: Core services importing Data services directly
- **Solution**: 
  - Create `IConnectionService` interface in Core layer
  - Create `ISeenMessageStore` interface in Core layer
  - Inject via DI instead of direct import
- **Complexity**: MEDIUM
- **Effort**: 6 hours

**3. Core → Data/Repositories (WIDESPREAD)**
- **Files**: 14 files across Core layer importing `data/repositories/*`
- **List**:
  1. `lib/core/app_core.dart` - imports ContactRepository, MessageRepository, etc.
  2. `lib/core/di/service_locator.dart` - imports repositories (OK for DI setup)
  3. `lib/core/bluetooth/handshake_coordinator.dart` - imports ContactRepository
  4. `lib/core/bluetooth/advertising_manager.dart` - imports IntroHintRepository
  5. `lib/core/bluetooth/smart_handshake_manager.dart` - imports ContactRepository
  6. `lib/core/messaging/offline_message_queue.dart` - imports ContactRepository, DatabaseHelper
  7. `lib/core/messaging/mesh_relay_engine.dart` - imports ContactRepository
  8. `lib/core/discovery/device_deduplication_manager.dart` - imports IntroHintRepository
  9. `lib/core/interfaces/i_security_manager.dart` - imports ContactRepository
  10. `lib/core/interfaces/i_contact_repository.dart` - imports ContactRepository (OK)
  11. `lib/core/security/contact_recognizer.dart` - imports ContactRepository
  12. `lib/core/security/hint_cache_manager.dart` - imports ContactRepository
  13. `lib/core/services/message_retry_coordinator.dart` - imports MessageRepository
  14. `lib/core/services/hint_scanner_service.dart` - imports ContactRepository
  15. `lib/core/services/security_manager.dart` - imports ContactRepository
  16. `lib/core/services/simple_crypto.dart` - imports ContactRepository

- **Problem**: Core layer directly accessing Data layer repositories
- **Solution**: Create `IRepositoryProvider` abstraction that Core receives via DI
- **Complexity**: MEDIUM-HIGH
- **Effort**: 1.5 days

---

## Phase 3 Solution Architecture

### 1. Create Core-Layer Interfaces

#### NEW FILE: `lib/core/interfaces/i_connection_service.dart`
```dart
abstract class IConnectionService {
  // Replace BLEService direct usage
  Stream<ConnectionEvent> get connectionStatusStream;
  Future<void> sendMessage(String recipient, String content);
  Future<void> startScanning();
  Future<void> stopScanning();
  // ... other critical BLE methods (not all 40+)
}
```

**Usage**: 
- `message_router.dart` → depends on `IConnectionService` instead of `BLEService`
- `BLEServiceFacade` implements `IConnectionService`

---

#### NEW FILE: `lib/core/interfaces/i_repository_provider.dart`
```dart
abstract class IRepositoryProvider {
  // Provides access to Data layer repositories
  IContactRepository get contactRepository;
  IMessageRepository get messageRepository;
  IIntroHintRepository get introHintRepository;
  IPreferencesRepository get preferencesRepository;
  // ... others as needed
}
```

**Usage**: 
- Core services receive `IRepositoryProvider` via constructor DI
- Never directly import `data/repositories/*`
- Example: `SecurityManager` → depends on `IRepositoryProvider` instead of `ContactRepository`

---

#### NEW FILE: `lib/core/interfaces/i_seen_message_store.dart`
```dart
abstract class ISeenMessageStore {
  Future<bool> hasSeenMessage(String messageHash);
  Future<void> recordSeenMessage(String messageHash, int seenAt);
  Future<void> performMaintenance();
}
```

**Usage**: 
- `MeshRelayEngine` → depends on `ISeenMessageStore` instead of `SeenMessageStore`

---

### 2. Refactor NavigationService (Remove Presentation Imports)

#### BEFORE:
```dart
import '../../presentation/screens/chat_screen.dart';
import '../../presentation/screens/contacts_screen.dart';

class NavigationService {
  void navigateToChat(String contactKey) {
    // Direct screen knowledge
  }
}
```

#### AFTER:
```dart
// NO presentation imports!

typedef NavigationCallback = Future<void> Function(String routeName, {required Map<String, dynamic> arguments});

class NavigationService {
  final NavigationCallback _navigate;
  
  NavigationService({required NavigationCallback navigate})
    : _navigate = navigate;
    
  void navigateToChat(String contactKey) {
    _navigate('chat', arguments: {'contactKey': contactKey});
  }
}
```

**In AppCore**:
```dart
final navigationService = NavigationService(
  navigate: (routeName, {required arguments}) async {
    // Navigator.pushNamed(context, routeName, arguments: arguments);
    // OR use GoRouter in app.dart
  }
);
```

---

### 3. Update Core Files to Use Abstractions

#### Pattern: Replace Direct Imports with Abstraction

**EXAMPLE: SecurityManager**

BEFORE:
```dart
import '../../data/repositories/contact_repository.dart';

class SecurityManager {
  final ContactRepository _contactRepository;
  
  SecurityManager(this._contactRepository);
  
  Future<Contact?> getContact(String key) {
    return _contactRepository.getContactByPublicKey(key);
  }
}
```

AFTER:
```dart
import '../interfaces/i_repository_provider.dart';

class SecurityManager {
  final IRepositoryProvider _repositoryProvider;
  
  SecurityManager(this._repositoryProvider);
  
  Future<Contact?> getContact(String key) {
    return _repositoryProvider.contactRepository.getContactByPublicKey(key);
  }
}
```

---

## Phase 3 Implementation Tasks

### Task 1: Create Interfaces (2-3 hours)
1. ✅ `IConnectionService` (40 methods, critical BLE operations only)
2. ✅ `IRepositoryProvider` (7 repositories)
3. ✅ `ISeenMessageStore` (3 methods)
4. ✅ `IIntroHintRepository` interface (if not exists)
5. ✅ `IPreferencesRepository` interface (if not exists)

### Task 2: Refactor NavigationService (1 hour)
1. Remove all presentation imports
2. Add callback-based navigation
3. Update AppCore to inject navigation callback
4. Add unit tests (2 tests)

### Task 3: Update 16 Core Files (1.5 days)
**Group A - Service layer (5 files)**:
1. `security_manager.dart`
2. `message_retry_coordinator.dart`
3. `hint_scanner_service.dart`
4. `simple_crypto.dart`
5. `app_core.dart` (partial)

**Group B - Bluetooth layer (3 files)**:
6. `handshake_coordinator.dart`
7. `advertising_manager.dart`
8. `smart_handshake_manager.dart`

**Group C - Messaging layer (2 files)**:
9. `message_router.dart` → use `IConnectionService`
10. `mesh_relay_engine.dart` → use `ISeenMessageStore`
11. `offline_message_queue.dart`

**Group D - Security/Discovery (3 files)**:
12. `contact_recognizer.dart`
13. `hint_cache_manager.dart`
14. `device_deduplication_manager.dart`

### Task 4: Update DI Container (2 hours)
1. Register all new interfaces in `service_locator.dart`
2. Create implementation for `IRepositoryProvider`
3. Inject `IConnectionService` into messaging layer
4. Inject `ISeenMessageStore` into relay engine

### Task 5: Write Tests (1 day)
- 5 tests for IConnectionService contract
- 5 tests for IRepositoryProvider contract
- 5 tests for NavigationService refactoring
- 5 integration tests (services using abstractions)

---

## Critical Invariants to Preserve

✅ **Identity Management**: publicKey immutable, ephemeralId per-session
✅ **Session Security**: Noise handshake before encryption
✅ **Message Routing**: Deterministic IDs, duplicate detection
✅ **Dual-role BLE**: Central + peripheral coexist
✅ **Mesh Relay**: Local delivery before forwarding

---

## Success Criteria

- [ ] NavigationService has ZERO presentation imports
- [ ] All Core → Data imports use abstract interfaces
- [ ] 16 affected files refactored to use DI
- [ ] 20+ new tests (all passing)
- [ ] Zero breaking changes
- [ ] Compilation without warnings
- [ ] Real device testing validates BLE functionality

---

## Files to Create

1. `lib/core/interfaces/i_connection_service.dart` (100 LOC)
2. `lib/core/interfaces/i_repository_provider.dart` (80 LOC)
3. `lib/core/interfaces/i_seen_message_store.dart` (30 LOC)
4. `lib/core/di/repository_provider_impl.dart` (80 LOC)
5. `test/core/phase3_integration_test.dart` (200 LOC)

---

## Files to Modify

16 production files (see Task 3 above)

---

## Estimated Timeline

- Task 1 (Interfaces): 3 hours
- Task 2 (NavigationService): 1 hour
- Task 3 (16 Core files): 1.5 days (12 hours)
- Task 4 (DI Container): 2 hours
- Task 5 (Testing): 1 day (8 hours)

**Total**: 2 weeks (if 4 hours/day) or 4 days (if 8 hours/day)

---

## Confidence Assessment

**Confidence Score**: 85/100 ✅

**Breakdown**:
- ✅ No duplicates (20%): Abstraction pattern proven
- ✅ Architecture compliance (20%): Follows SOLID principles, DI pattern
- ✅ Official docs verified (15%): Dart interfaces, DI best practices
- ✅ Working reference (15%): Used in Phase 1 & 2 successfully
- ✅ Root cause identified (15%): Layer violations clearly documented
- ⚠️ Codex opinion (0%): Not consulted (optional for this score)

**Not 100% because**: Some Core files have complex interdependencies that may require careful refactoring, but nothing unexpected.

---

**Ready to proceed with Phase 3?** ✅ YES
