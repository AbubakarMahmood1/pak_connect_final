# SUMMARY: How to Mock AppCore's Dependencies

## Answer to Each Question

### 1. setupServiceLocator() - What it does
Initializes GetIt with ALL core interfaces. Key steps:
- Registers ISharedMessageQueueProvider (AppCoreSharedMessageQueueProvider)
- Calls data layer registrar callback to register concrete repos
- Validates IContactRepository and IMessageRepository exist
- Creates IRepositoryProvider (RepositoryProviderImpl)
- Registers factory interfaces for factories

### 2. registerInitializedServices() - What it does
Called AFTER AppCore initializes core services. Registers:
- ISecurityService
- IConnectionService (as IMeshBleService, IConnectionService, optional IBLEServiceFacade)
- MeshNetworkingService + IMeshNetworkingService
- Optional mesh coordination services

### 3. configureDataLayerRegistrar() - What it does
Sets a callback function that runs during setupServiceLocator(). This callback:
- Registers all concrete repository implementations
- Registers all data services
- Keeps core DI decoupled from data layer
- MUST be called BEFORE setupServiceLocator()

### 4. registerDataLayerServices() - What it does
The actual callback implementation that:
- Configures dependency resolvers for BLE, message handling, relay services
- Registers 8 repositories (Contact, Message, Archive, Chats, Preferences, Group, IntroHint, MeshRouting)
- Registers 7+ supporting services
- All registered as singletons

### 5. Key interfaces resolved from getIt
**CRITICAL LIST:**
- IRepositoryProvider - main access point
- IContactRepository - contacts
- IMessageRepository - messages
- IArchiveRepository - archives
- IChatsRepository - chats
- IConnectionService - BLE comms
- ISharedMessageQueueProvider - offline queue
- IBLEServiceFacade - BLE interface
- IMeshNetworkingService - mesh routing
- IDatabaseProvider - database
- ISeenMessageStore - deduplication
- IUserPreferences - user preferences
- IPreferencesRepository - app preferences

### 6. Test mocking patterns
**HAND-WRITTEN FAKES (Preferred)**:
- test/test_helpers/mocks/mock_contact_repository.dart
- test/test_helpers/mocks/mock_message_repository.dart
- test/test_helpers/mocks/mock_connection_service.dart
- test/test_helpers/mocks/mock_flutter_secure_storage.dart
- test/test_helpers/mocks/in_memory_secure_storage.dart
- test/test_helpers/messaging/in_memory_offline_message_queue.dart
- test/test_helpers/ble/fake_ble_service.dart
- test/test_helpers/ble/fake_ble_platform.dart
- test/test_helpers/test_seen_message_store.dart

**MOCKITO (Alternative)**:
- mockito: ^5.4.4 in pubspec.yaml
- Use @GenerateNiceMocks([MockSpec<T>()]) annotations
- when() to stub return values
- verify() to check calls
- Examples: test/data/services/ble_messaging_service_test.dart

### 7. PerformanceMonitor DI setup
❌ **NO DI NEEDED** - Standalone service
- Just instantiate: inal monitor = PerformanceMonitor()
- Initialize: wait monitor.initialize()
- Use directly: monitor.startMonitoring(), monitor.startOperation(), etc.
- No dependencies on other services

### 8. BatteryOptimizer DI setup
❌ **NO DI NEEDED** - Singleton pattern
- Disable platform calls in tests: BatteryOptimizer.disableForTests()
- Instantiate: inal optimizer = BatteryOptimizer()
- Initialize: wait optimizer.initialize()
- Register callbacks: optimizer.onBatteryUpdate = (info) => ...
- No dependencies on domain/data layers

### 9. Offline queue components DI setup
⚠️ **OPTIONAL DI** - Hybrid approach
- OfflineQueueFacade: Accepts optional OfflineMessageQueue
- OfflineMessageQueue: Accepts optional repositories
- Both work standalone with defaults
- Can inject IMessageQueueRepository, IQueuePersistenceManager, IRetryScheduler
- No required DI container setup
- Use InMemoryOfflineMessageQueue for testing

### 10. QueuedMessage constructor
`dart
QueuedMessage({
  required String id,
  required String chatId,
  required String content,
  required String recipientPublicKey,
  required String senderPublicKey,
  required MessagePriority priority,    // MUTABLE
  required DateTime queuedAt,
  required int maxRetries,
  String? replyToMessageId,
  List<String> attachments = const [],
  QueuedMessageStatus status = QueuedMessageStatus.pending,  // MUTABLE
  int attempts = 0,  // MUTABLE
  DateTime? lastAttemptAt,
  DateTime? nextRetryAt,
  DateTime? deliveredAt,
  DateTime? failedAt,
  String? failureReason,
  DateTime? expiresAt,
  bool isRelayMessage = false,
  RelayMetadata? relayMetadata,
  String? originalMessageId,
  String? relayNodeId,
  String? messageHash,
  int senderRateCount = 0,
})
`

### 11. EnhancedMessage
**Extends Message**, adds:
- replyToMessageId, threadId, metadata
- deliveryReceipt, readReceipt
- reactions, isStarred, isForwarded
- priority (MessagePriority)
- editedAt, originalContent
- attachments, encryptionInfo

**MessageStatus enum**:
`
enum MessageStatus {
  sending,    // Being sent
  sent,       // Acknowledged
  delivered,  // Delivered to recipient
  failed,     // Failed to deliver
  read,       // Read by recipient
}
`

### 12. Is mockito in pubspec.yaml?
✅ **YES** - mockito: ^5.4.4 is included in dev_dependencies

---

## RECOMMENDED TESTING SETUP

### For most tests:
`dart
import 'package:pak_connect/test_helpers/test_setup.dart';
import 'package:pak_connect/test_helpers/mocks/mock_contact_repository.dart';
import 'package:pak_connect/test_helpers/mocks/mock_message_repository.dart';

setUp(() async {
  await TestSetup.initializeTestEnvironment(
    dbLabel: 'my_test',
    configureDiWithMocks: true,
    contactRepository: MockContactRepository(),
    messageRepository: MockMessageRepository(),
  );
});
`

### For offline queue testing:
`dart
import 'package:pak_connect/core/messaging/offline_queue_facade.dart';
import 'package:pak_connect/test_helpers/messaging/in_memory_offline_message_queue.dart';

final queue = OfflineQueueFacade(
  queue: InMemoryOfflineMessageQueue(),
);
await queue.initialize();
`

### For BLE testing:
`dart
import 'package:pak_connect/test_helpers/mocks/mock_connection_service.dart';

final mockConnection = MockConnectionService();
mockConnection.emitIncomingMessage(payload);
mockConnection.emitDiscoveredDevices(peripherals);
`

### For performance/battery testing:
`dart
import 'package:pak_connect/domain/services/performance_monitor.dart';
import 'package:pak_connect/domain/services/battery_optimizer.dart';

// No DI needed - standalone
BatteryOptimizer.disableForTests();
final monitor = PerformanceMonitor();
await monitor.initialize();
`

---

## QUICK CHECKLIST FOR NEW TEST

- [ ] Import TestSetup from test/core/test_helpers/test_setup.dart
- [ ] Call TestSetup.initializeTestEnvironment() in setUp()
- [ ] Use MockContactRepository / MockMessageRepository / etc. if needed
- [ ] For offline queue: use InMemoryOfflineMessageQueue
- [ ] For BLE: use MockConnectionService
- [ ] For performance/battery: instantiate directly, no DI
- [ ] Always call TestSetup.cleanupDatabase() in tearDown()
- [ ] Use getIt.get<T>() to access registered services

