# AppCore DI & Mocking Documentation Index

This documentation package contains everything you need to understand and mock AppCore's dependency injection system.

## Documents in This Package

### 1. **DI_MOCKING_SUMMARY.md** (COMPREHENSIVE)
The complete, in-depth reference covering:
- setupServiceLocator(), registerInitializedServices(), configureDataLayerRegistrar()
- registerDataLayerServices() implementation
- All key interfaces resolved from GetIt
- Both mocking patterns (hand-written fakes vs mockito)
- PerformanceMonitor, BatteryOptimizer DI setup
- Offline queue components (OfflineQueueFacade, OfflineMessageQueue)
- QueuedMessage and EnhancedMessage entities
- Full testing setup explanation
- 22 KB of detailed information

**Use when**: You need complete technical understanding or reference

### 2. **QUICK_REFERENCE.md** (QUICK LOOKUP)
One-page quick lookup with:
- Test environment initialization
- The 4 core services to mock
- Critical interfaces in GetIt
- Offline queue quick example
- PerformanceMonitor/BatteryOptimizer quick examples
- QueuedMessage quick reference
- EnhancedMessage and MessageStatus

**Use when**: You need a quick reminder while coding

### 3. **MOCKING_EXAMPLES.md** (PRACTICAL CODE)
8 concrete, copy-paste-ready examples:
1. Basic unit test with mocked repositories
2. Testing offline queue
3. Testing BLE communication with mocked connection
4. Testing PerformanceMonitor
5. Testing BatteryOptimizer
6. Creating custom hand-written mock
7. Using Repository Provider
8. Full integration test

**Use when**: You need working code examples to reference

### 4. **TESTING_SUMMARY.md** (CHECKLIST)
Answers all 12 questions concisely plus:
- Recommended testing setup patterns
- Quick checklist for new tests
- All critical information in one place

**Use when**: You need answers to specific questions or a quick checklist

### 5. **README.md** (THIS FILE)
Navigation guide for all documentation

---

## Quick Navigation by Topic

### Understanding DI Setup
1. Start with: **TESTING_SUMMARY.md** (questions 1-3)
2. Deep dive: **DI_MOCKING_SUMMARY.md** (sections 1-3)
3. See examples: **MOCKING_EXAMPLES.md** (example 7-8)

### Writing Tests
1. Check: **QUICK_REFERENCE.md** (Critical DI Flow)
2. Follow: **TESTING_SUMMARY.md** (Recommended Testing Setup)
3. Copy: **MOCKING_EXAMPLES.md** (examples 1-3)

### Mocking Specific Components
- **Repositories**: MOCKING_EXAMPLES.md (example 1)
- **Offline Queue**: MOCKING_EXAMPLES.md (example 2)
- **BLE Communication**: MOCKING_EXAMPLES.md (example 3)
- **Performance Monitor**: MOCKING_EXAMPLES.md (example 4)
- **Battery Optimizer**: MOCKING_EXAMPLES.md (example 5)
- **Custom Mocks**: MOCKING_EXAMPLES.md (example 6)

### Understanding Entities
- QueuedMessage: QUICK_REFERENCE.md + TESTING_SUMMARY.md (question 10)
- EnhancedMessage/MessageStatus: QUICK_REFERENCE.md + TESTING_SUMMARY.md (question 11)

### Choosing Mocking Strategy
Read: DI_MOCKING_SUMMARY.md (section 4) or TESTING_SUMMARY.md (question 6)

---

## The 3-Minute Overview

### DI Architecture
1. **setupServiceLocator()** - initializes GetIt with core interfaces
2. **configureDataLayerRegistrar()** - sets callback to register data layer
3. **registerInitializedServices()** - registers runtime-initialized services
4. Result: Full DI graph with all interfaces available

### Key Interfaces (What You'll Use Most)
- IRepositoryProvider - unified access to all repositories
- IContactRepository, IMessageRepository - data access
- IConnectionService - BLE communication
- ISeenMessageStore, ISharedMessageQueueProvider - queue/dedup

### Mocking Strategy
**PREFERRED**: Hand-written fakes (MockContactRepository, MockConnectionService)
- Simpler, more readable, no code generation
- Located in test/test_helpers/mocks/

**ALTERNATIVE**: Mockito when you need sophisticated verification

### Test Setup (3 lines)
`dart
setUp(() async {
  await TestSetup.initializeTestEnvironment(
    configureDiWithMocks: true,
    contactRepository: MockContactRepository(),
  );
});
`

### Components That Don't Need DI
- PerformanceMonitor
- BatteryOptimizer
- OfflineQueueFacade / OfflineMessageQueue (optional injection)

---

## File Locations in Codebase

### Core DI Files
- lib/core/di/service_locator.dart - setupServiceLocator(), registerInitializedServices()
- lib/data/di/data_layer_service_registrar.dart - registerDataLayerServices()

### Mock/Test Files
- 	est/core/test_helpers/test_setup.dart - TestSetup.initializeTestEnvironment()
- 	est/test_helpers/mocks/ - Hand-written mocks
- 	est/test_helpers/messaging/ - Queue mocks
- 	est/test_helpers/ble/ - BLE mocks

### Entity Files
- lib/domain/entities/queued_message.dart - QueuedMessage
- lib/domain/entities/enhanced_message.dart - EnhancedMessage

### Standalone Services
- lib/domain/services/performance_monitor.dart - No DI
- lib/domain/services/battery_optimizer.dart - No DI

### Queue Components
- lib/core/messaging/offline_queue_facade.dart - Facade with lazy init
- lib/core/messaging/offline_message_queue.dart - Core queue implementation

---

## Key Facts to Remember

1. ✅ mockito IS in pubspec.yaml (version 5.4.4)
2. ❌ PerformanceMonitor and BatteryOptimizer DO NOT need DI
3. ⚠️ OfflineQueue has OPTIONAL DI (works standalone)
4. 🎯 Use hand-written fakes, reserve mockito for complex cases
5. 📦 IRepositoryProvider is the main entry point
6. 🔄 Always call TestSetup.initializeTestEnvironment() in setUp()
7. 🏗️ GetIt is singleton and idempotent (safe to call multiple times)
8. 📋 QueuedMessage.priority is MUTABLE (can change after creation)
9. 📨 MessageStatus has 5 states: sending, sent, delivered, failed, read
10. 🔌 configureDataLayerRegistrar() must be called BEFORE setupServiceLocator()

---

## Common Tasks & Where to Find Info

| Task | Document | Section |
|------|----------|---------|
| Start new test file | MOCKING_EXAMPLES.md | Examples 1-3 |
| Mock a repository | MOCKING_EXAMPLES.md | Example 6 |
| Mock BLE service | MOCKING_EXAMPLES.md | Example 3 |
| Test offline queue | MOCKING_EXAMPLES.md | Example 2 |
| Understand DI flow | TESTING_SUMMARY.md | Answers 1-5 |
| Check interfaces | QUICK_REFERENCE.md | "Critical Interfaces" |
| QueuedMessage fields | TESTING_SUMMARY.md | Answer 10 |
| MessageStatus values | TESTING_SUMMARY.md | Answer 11 |
| Mocking strategy | DI_MOCKING_SUMMARY.md | Section 4 |
| Test checklist | TESTING_SUMMARY.md | Quick Checklist |

---

## Still Have Questions?

1. **"How do I mock X?"** → See MOCKING_EXAMPLES.md
2. **"What does Y do?"** → See DI_MOCKING_SUMMARY.md or TESTING_SUMMARY.md
3. **"What's the quick way to Z?"** → See QUICK_REFERENCE.md
4. **"Am I testing this correctly?"** → See TESTING_SUMMARY.md (Quick Checklist)

---

Created: 2026-03-07 09:24:34
