## AppCore's DI Setup and Mocking Patterns - Complete Summary

### 1. SERVICE LOCATOR SETUP (lib/core/di/service_locator.dart)

#### setupServiceLocator()
- **Purpose**: Initializes the GetIt dependency injection container
- **What it does**:
  - Checks if core-facing contracts are already registered (idempotent)
  - Registers ISharedMessageQueueProvider (AppCoreSharedMessageQueueProvider) as singleton
  - Calls the data layer registrar callback to register concrete repositories
  - Validates that IContactRepository and IMessageRepository are registered
  - Creates and registers IRepositoryProvider (RepositoryProviderImpl)
  - Registers factory interfaces: IHomeScreenFacadeFactory, IChatConnectionManagerFactory, IChatListCoordinatorFactory, IHandshakeCoordinatorFactory, IMeshRelayEngineFactory
  - Notes that SecurityManager, BLEService, MeshNetworkingService will be initialized by AppCore in _initializeCoreServices()

#### registerInitializedServices()
- **Purpose**: Registers services AFTER they've been initialized by AppCore
- **Parameters**:
  - securityService: ISecurityService - registered as both ISecurityService 
  - connectionService: IConnectionService - registered as IMeshBleService, IConnectionService, and potentially IBLEServiceFacade
  - meshNetworkingService: MeshNetworkingService - registered as both concrete class and interface
  - Optional: meshRelayCoordinator, meshQueueSyncCoordinator, meshHealthMonitor
- **What it does**:
  - Configures SecurityServiceLocator with the security service
  - Registers security, connection, and mesh networking services
  - Registers optional mesh coordination services

#### configureDataLayerRegistrar()
- **Purpose**: Sets a callback function that registers all data-layer concrete services
- **Type**: 	ypedef DataLayerRegistrar = Future<void> Function(GetIt getIt, Logger logger)
- **Called during**: setupServiceLocator() to decouple core DI from data layer implementations
- **Must be called before**: setupServiceLocator()

### 2. DATA LAYER REGISTRAR (lib/data/di/data_layer_service_registrar.dart)

#### registerDataLayerServices()
- **Purpose**: Concrete implementation that registers all data-layer repositories and services
- **What it does**:
  1. **Configures dependency resolvers** for multiple data services:
     - BLEHandshakeService
     - BLEServiceFacade
     - BLEMessageHandlerFacade / BLEMessageHandlerFacadeImpl
     - ProtocolMessageHandler
     - RelayCoordinator
     - MeshRelayHandler
     - EphemeralContactCleaner

  2. **Registers repositories** as singletons:
     - ContactRepository (concrete) + IContactRepository (interface)
     - MessageRepository (concrete) + IMessageRepository (interface)
     - ArchiveRepository (concrete) + IArchiveRepository (interface)
     - ChatsRepository (concrete) + IChatsRepository (interface)
     - PreferencesRepository (concrete) + IPreferencesRepository (interface)
     - GroupRepository (concrete) + IGroupRepository (interface)
     - IntroHintRepository (concrete) + IIntroHintRepository (interface)
     - MeshRoutingService (concrete) + IMeshRoutingService (interface)

  3. **Registers services** as lazy singletons:
     - IUserPreferences (UserPreferences)
     - IExportService (ExportServiceAdapter)
     - IImportService (ImportServiceAdapter)
     - ISeenMessageStore (SeenMessageStore)
     - IDatabaseProvider (DatabaseProvider)
     - IBLEMessageHandlerFacade (BLEMessageHandlerFacadeImpl)
     - IBLEServiceFacadeFactory (DataBleServiceFacadeFactory)

### 3. KEY INTERFACES RESOLVED FROM GetIt (in lib/core/app_core.dart)

The following interfaces are retrieved via getIt.get<T>() calls:
- **Repositories**:
  - IPreferencesRepository - preferences storage
  - IContactRepository - contact data access
  - IMessageRepository - message data access
  - IArchiveRepository - archived messages/chats
  - IChatsRepository - chat metadata
  - IUserPreferences - user-level preferences

- **Core Services**:
  - IDatabaseProvider - database access
  - ISeenMessageStore - deduplication tracking
  - ISharedMessageQueueProvider - shared offline queue
  - IRepositoryProvider - unified repository access
  - IBLEServiceFacade or create via IBLEServiceFacadeFactory.create()
  - IMeshRelayEngineFactory.create() - creates relay engine instances

### 4. MOCKING PATTERNS (Found in test/)

#### Pattern 1: Hand-Written Fakes (PREFERRED for tests)
Located in 	est/test_helpers/:
- **MockContactRepository** (extends ContactRepository) - in-memory store
- **MockMessageRepository** (extends MessageRepository) - in-memory store
- **MockConnectionService** (implements IConnectionService) - full mock with StreamControllers
- **InMemoryOfflineMessageQueue** (implements OfflineMessageQueueContract) - no database
- **InMemorySecureStorage** (extends FlutterSecureStoragePlatform) - volatile storage
- **MockFlutterSecureStorage** (implements FlutterSecureStorage) - simple mock
- **FakeBleService**, **FakeBleplatform** - BLE mock implementations
- **TestSeenMessageStore** (implements ISeenMessageStore) - in-memory dedup

**Advantages**:
- Full control over behavior
- No code generation overhead
- Clear, readable test setup
- Easy to add helper methods (e.g., mitIncomingMessage(), mitDiscoveredDevices())

#### Pattern 2: Mockito (Used for specific service tests)
- **Imports**: import 'package:mockito/annotations.dart' + import 'package:mockito/mockito.dart'
- **Annotation**: @GenerateNiceMocks([MockSpec<SomeClass>()]) 
- **Example**: 	est/data/services/ble_messaging_service_test.dart uses MockBLEConnectionManager, MockIBLEStateManagerFacade, etc.
- **Setup**: esetMockitoState(), when() clauses, verify with erify()

**When to use**:
- Testing specific method calls with exact argument matching
- When testing behavior that requires stubbing return values
- Integration with specific service behavior verification

### 5. PERFORMANCE MONITOR (lib/domain/services/performance_monitor.dart)

**DI Setup**: ❌ **NO DI needed**
- **Pattern**: Standalone service with static logger
- **Initialization**: Future<void> initialize() async method
- **Usage**: Call initialize() manually, then use startMonitoring(), startOperation(), ndOperation()
- **No dependencies** on other services
- **Mutable state** for tracking operations and metrics

### 6. BATTERY OPTIMIZER (lib/domain/services/battery_optimizer.dart)

**DI Setup**: ❌ **NO DI needed**
- **Pattern**: Singleton via factory constructor with internal _instance
- **Test mode**: Has static void disableForTests() to skip platform calls
- **Initialization**: Future<void> initialize() async method
- **Uses native plugin**: attery_plus (Battery plugin - wrapped to avoid MethodChannel issues in tests)
- **Callbacks**: onBatteryUpdate, onPowerModeChanged for event handling
- **No dependencies** on domain/data layers
- **Tests call**: BatteryOptimizer.disableForTests() in TestSetup.initializeTestEnvironment()

### 7. OFFLINE QUEUE COMPONENTS

#### offline_queue_facade.dart
**DI Setup**: ⚠️ **Hybrid approach**
- **Pattern**: Facade over OfflineMessageQueue with lazy-initialized sub-services
- **Constructor**: Accepts optional OfflineMessageQueue instance (uses default if not provided)
- **Lazy initialization**: Sub-services initialized on first access:
  - IMessageQueueRepository - lazy created as MessageQueueRepository()
  - IRetryScheduler - lazy created as RetryScheduler()
  - IQueueSyncCoordinator - lazy created as QueueSyncCoordinator()
  - IQueuePersistenceManager - lazy created as QueuePersistenceManager()
- **Initialization method**: Future<void> initialize(...) accepts all callbacks
- **No required DI** - works standalone or can receive injected repositories

#### offline_message_queue.dart
**DI Setup**: ⚠️ **Hybrid approach**
- **Constructor**: Accepts optional repositories: IMessageQueueRepository?, IQueuePersistenceManager?, IRetryScheduler?
- **Static configurable default**: static void configureDefaultRepositoryProvider(IRepositoryProvider)
- **Dual-queue system**: Separates direct messages (80% bandwidth) from relay messages (20%)
- **Initialization**: Future<void> initialize(...) with callbacks and optional repositories
- **Late-initialized dependencies**: Creates sub-components if not provided
- **Repository provider**: Can be configured globally or passed during initialization

### 8. QUEUED MESSAGE (lib/domain/entities/queued_message.dart)

**Constructor**:
`dart
QueuedMessage({
  required String id,
  required String chatId,
  required String content,
  required String recipientPublicKey,
  required String senderPublicKey,
  required MessagePriority priority,
  required DateTime queuedAt,
  required int maxRetries,
  String? replyToMessageId,
  List<String> attachments = const [],
  QueuedMessageStatus status = QueuedMessageStatus.pending,
  int attempts = 0,
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

**Key fields**:
- status: QueuedMessageStatus - mutable (pending, sent, delivered, failed)
- ttempts: int - delivery attempt count
- priority: MessagePriority - mutable for priority changes
- Relay-specific: isRelayMessage, elayMetadata, originalMessageId, elayNodeId, messageHash
- TTL based on priority: urgent=24h, high=12h, normal=6h, low=3h

### 9. ENHANCED MESSAGE (lib/domain/entities/enhanced_message.dart)

**Class hierarchy**: EnhancedMessage extends Message

**Additional fields**:
- eplyToMessageId: MessageId?
- 	hreadId: String?
- metadata: Map<String, dynamic>?
- deliveryReceipt: MessageDeliveryReceipt?
- eadReceipt: MessageReadReceipt?
- eactions: List<MessageReaction>
- isStarred: bool
- isForwarded: bool
- priority: MessagePriority
- ditedAt: DateTime?
- originalContent: String?
- ttachments: List<MessageAttachment>
- ncryptionInfo: MessageEncryptionInfo?

**MessageStatus enum**:
`
enum MessageStatus {
  sending,    // Being sent
  sent,       // Acknowledged by peer
  delivered,  // Delivered to recipient
  failed,     // Failed to deliver
  read,       // Read by recipient (if receipts enabled)
}
`

### 10. MOCKITO IN PUBSPEC.YAML

✅ **YES, mockito is included**:
`yaml
dev_dependencies:
  mockito: ^5.4.4  # Mock generation for testing (Phase 1 - P2 Refactoring)
`

---

## TESTING SETUP SUMMARY

The test harness (	est/core/test_helpers/test_setup.dart) provides:

### TestSetup.initializeTestEnvironment()
`dart
static Future<void> initializeTestEnvironment({
  String? dbLabel,
  bool useRealServiceLocator = true,
  bool configureDiWithMocks = false,
  IContactRepository? contactRepository,
  IMessageRepository? messageRepository,
  ISeenMessageStore? seenMessageStore,
  IConnectionService? connectionService,
  IChatsRepository? chatsRepository,
  IArchiveRepository? archiveRepository,
}) async
`

**Initializes**:
1. FlutterBinding
2. FakeBlePlatform for BLE mocking
3. InMemorySecureStorage
4. DatabaseEncryption with mock storage
5. BatteryOptimizer.disableForTests()
6. TopologyManager
7. SQLite FFI
8. Test database
9. SharedPreferences
10. Service locator (via configureDataLayerRegistrar + setupServiceLocator)
11. Default dependencies from locator
12. AppServices snapshot

### TestSetup.configureTestDI()
Allows overriding specific repositories:
- Uses default MockContactRepository if none provided
- Uses default MockMessageRepository if none provided
- Uses real SeenMessageStore by default
- Unregisters and re-registers specific types
- Maintains consistency of IRepositoryProvider

### Key Pattern: Adapter Pattern
For repositories not extending the concrete base:
`dart
final contactConcrete = contactRepo is ContactRepository
    ? contactRepo
    : _ContactRepositoryAdapter(contactRepo);
`
This allows mocks that only implement the interface.

---

## RECOMMENDED MOCKING APPROACH

1. **Use hand-written fakes** for most tests (MockContactRepository, MockConnectionService, etc.)
2. **Use mockito only** when you need sophisticated argument matching or verification
3. **For offline queue testing**: Use InMemoryOfflineMessageQueue or pass mock repositories to OfflineMessageQueue constructor
4. **Always reset state**: Call TestSetup.initializeTestEnvironment() in setUp()
5. **For PerformanceMonitor/BatteryOptimizer**: Just instantiate and use, no DI needed

