// Shared test harness utilities for pak_connect tests

import 'package:flutter/foundation.dart' show debugPrint;
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/di/app_services.dart';
import 'package:pak_connect/core/di/service_locator.dart' as di_service_locator;
import 'package:pak_connect/core/di/repository_provider_impl.dart';
import 'package:pak_connect/core/bluetooth/handshake_coordinator.dart';
import 'package:pak_connect/core/bluetooth/smart_handshake_manager.dart';
import 'package:pak_connect/core/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/services/message_queue_repository.dart';
import 'package:pak_connect/core/services/queue_persistence_manager.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/interfaces/i_preferences_repository.dart';
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/interfaces/i_user_preferences.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/routing/topology_manager.dart';
import 'package:pak_connect/domain/services/archive_management_service.dart';
import 'package:pak_connect/domain/services/archive_search_service.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/services/contact_management_service.dart';
import 'package:pak_connect/domain/services/hint_scanner_service.dart';
import 'package:pak_connect/domain/services/mesh/mesh_network_health_monitor.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart'
    show MeshNetworkingService, PendingBinaryTransfer, ReceivedBinaryEvent;
import 'package:pak_connect/domain/services/message_router.dart';
import 'package:pak_connect/data/database/database_encryption.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/di/data_layer_service_registrar.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/data/services/seen_message_store.dart';
import 'package:pak_connect/data/services/ble_handshake_service.dart';
import 'package:pak_connect/data/services/ble_message_handler_facade.dart';
import 'package:pak_connect/data/services/ble_message_handler_facade_impl.dart';
import 'package:pak_connect/data/services/ble_service_facade.dart';
import 'package:pak_connect/data/services/ephemeral_contact_cleaner.dart';
import 'package:pak_connect/data/services/mesh_relay_handler.dart';
import 'package:pak_connect/data/services/protocol_message_handler.dart';
import 'package:pak_connect/data/services/relay_coordinator.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/constants/binary_payload_types.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqflite.dart' as sqflite_common;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pak_connect/domain/services/battery_optimizer.dart';

import '../../test_helpers/ble/fake_ble_platform.dart';
import '../../test_helpers/mocks/in_memory_secure_storage.dart';
import '../../test_helpers/mocks/mock_flutter_secure_storage.dart';
import '../../test_helpers/mocks/mock_contact_repository.dart';
import '../../test_helpers/mocks/mock_connection_service.dart';
import '../../test_helpers/mocks/mock_message_repository.dart';
import '../../test_helpers/sqlite/native_sqlite_loader.dart';
import 'package:pak_connect/domain/models/security_level.dart';

/// Test harness utilities shared across suites.
class TestSetup {
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
  }) async {
    TestWidgetsFlutterBinding.ensureInitialized();

    FakeBlePlatform.ensureRegistered();
    FlutterSecureStoragePlatform.instance = InMemorySecureStorage();
    DatabaseEncryption.overrideSecureStorage(MockFlutterSecureStorage());
    BatteryOptimizer.disableForTests();

    final topologyManager = TopologyManager.instance;
    final nodeId = 'test-node-${DateTime.now().millisecondsSinceEpoch}';
    topologyManager.initializeForTests(nodeId.padRight(8, '0'));

    NativeSqliteLoader.ensureInitialized();
    sqfliteFfiInit();
    sqflite_common.databaseFactory = createDatabaseFactoryFfi(
      ffiInit: NativeSqliteLoader.ensureInitialized,
    );

    await configureTestDatabase(label: dbLabel);

    resetSharedPreferences();
    await resetDIServiceLocator();
    di_service_locator.configureDataLayerRegistrar(registerDataLayerServices);
    await di_service_locator.setupServiceLocator();
    _configureDefaultDependenciesFromLocator(GetIt.instance);
    _registerAppServicesSnapshot(GetIt.instance);

    if (configureDiWithMocks) {
      await configureTestDI(
        contactRepository: contactRepository,
        messageRepository: messageRepository,
        seenMessageStore: seenMessageStore,
        connectionService: connectionService,
        chatsRepository: chatsRepository,
        archiveRepository: archiveRepository,
        resetGraph: false,
      );
    }
    setupTestLogging();
  }

  static void setupTestLogging({Level level = Level.WARNING}) {
    Logger.root.level = level;
    Logger.root.clearListeners();
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.message}');
    });
  }

  static Future<void> configureTestDatabase({String? label}) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final sanitized = _sanitize(label ?? 'suite');
    final dbName = 'pak_connect_test_${sanitized}_$timestamp.db';
    await DatabaseHelper.close();
    DatabaseHelper.setTestDatabaseName(dbName);
    await DatabaseHelper.deleteDatabase();
  }

  static Future<void> configureTestDI({
    IContactRepository? contactRepository,
    IMessageRepository? messageRepository,
    ISeenMessageStore? seenMessageStore,
    IConnectionService? connectionService,
    IChatsRepository? chatsRepository,
    IArchiveRepository? archiveRepository,
    IDatabaseProvider? databaseProvider,
    bool resetGraph = false,
  }) async {
    final locator = GetIt.instance;

    // Detect if no overrides were provided so we can optionally reset to a clean graph
    final noOverridesProvided =
        contactRepository == null &&
        messageRepository == null &&
        seenMessageStore == null &&
        connectionService == null &&
        chatsRepository == null &&
        archiveRepository == null &&
        databaseProvider == null;

    // Reset GetIt if explicitly requested or when no overrides are provided to start from a clean graph
    if (resetGraph || noOverridesProvided) {
      await resetDIServiceLocator();
      di_service_locator.configureDataLayerRegistrar(registerDataLayerServices);
      await di_service_locator.setupServiceLocator();
    }

    void override<T extends Object>(T instance) {
      if (locator.isRegistered<T>()) {
        locator.unregister<T>();
      }
      locator.registerSingleton<T>(instance);
    }

    // Use provided repositories or default to mocks; always override concrete registrations
    final contactRepo = contactRepository ?? MockContactRepository();
    final contactConcrete = contactRepo is ContactRepository
        ? contactRepo
        : _ContactRepositoryAdapter(contactRepo);

    final messageRepo = messageRepository ?? MockMessageRepository();
    final messageConcrete = messageRepo is MessageRepository
        ? messageRepo
        : _MessageRepositoryAdapter(messageRepo);

    override<IContactRepository>(contactRepo);
    override<ContactRepository>(contactConcrete);

    override<IMessageRepository>(messageRepo);
    override<MessageRepository>(messageConcrete);
    if (databaseProvider != null) {
      override<IDatabaseProvider>(databaseProvider);
    }

    final store =
        seenMessageStore ??
        (locator.isRegistered<ISeenMessageStore>()
            ? locator<ISeenMessageStore>()
            : SeenMessageStore.instance);
    if (store is SeenMessageStore) {
      await store.initialize();
    }
    if (seenMessageStore != null ||
        !locator.isRegistered<ISeenMessageStore>()) {
      override<ISeenMessageStore>(store);
    }

    if (connectionService != null) {
      override<IConnectionService>(connectionService);
    }
    if (chatsRepository != null) {
      override<IChatsRepository>(chatsRepository);
    }
    if (archiveRepository != null) {
      override<IArchiveRepository>(archiveRepository);
    }

    // Keep repository provider aligned with active repository bindings.
    final finalContactRepo = locator<IContactRepository>();
    final finalMessageRepo = locator<IMessageRepository>();
    override<IRepositoryProvider>(
      RepositoryProviderImpl(
        contactRepository: finalContactRepo,
        messageRepository: finalMessageRepo,
      ),
    );

    _configureDefaultDependenciesFromLocator(locator);
    _registerAppServicesSnapshot(
      locator,
      preferredConnectionService: connectionService,
    );
  }

  static Future<void> cleanupDatabase() async {
    try {
      await DatabaseHelper.close();
      await DatabaseHelper.deleteDatabase();
    } catch (e) {
      debugPrint('Warning: Database cleanup error: $e');
    }
  }

  static Future<void> nukeDatabase() async {
    try {
      final db = await DatabaseHelper.database;
      await db.execute('PRAGMA foreign_keys = OFF');
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
      );
      for (final table in tables) {
        final name = table['name'] as String;
        await db.delete(name);
      }
      await db.execute('PRAGMA foreign_keys = ON');
    } catch (e) {
      debugPrint('Warning: Database nuke error: $e');
    }
  }

  static Future<void> fullDatabaseReset() async {
    try {
      await DatabaseHelper.close();
      final db = await DatabaseHelper.database;
      await db.execute('PRAGMA writable_schema = ON');
      await db.execute(
        "DELETE FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
      );
      await db.execute('PRAGMA writable_schema = OFF');
      await db.execute('PRAGMA user_version = 0');
      await db.execute('VACUUM');
      await DatabaseHelper.close();
    } catch (e) {
      debugPrint('Warning: Full database reset error: $e');
    }
  }

  static void resetSharedPreferences() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
  }

  static Future<void> resetDIServiceLocator() async {
    try {
      HintScannerService.clearRepositoryProvider();
      OfflineMessageQueue.clearDefaultRepositoryProvider();
      MessageQueueRepository.clearDefaultDatabaseProvider();
      QueuePersistenceManager.clearDefaultDatabaseProvider();
      MessageRouter.clearDependencyResolvers();
      ContactManagementService.clearDependencyResolvers();
      ArchiveManagementService.clearArchiveRepositoryResolver();
      ArchiveSearchService.clearArchiveRepositoryResolver();
      ChatManagementService.clearDependencyResolvers();
      HandshakeCoordinator.clearRepositoryProviderResolver();
      SmartHandshakeManager.clearRepositoryProviderResolver();
      MeshRelayEngine.clearDependencyResolvers();
      SecurityManager.clearContactRepositoryResolver();
      ProtocolMessageHandler.clearIdentityManagerResolver();
      RelayCoordinator.clearDependencyResolvers();
      MeshRelayHandler.clearRelayEngineFactoryResolver();
      EphemeralContactCleaner.clearQueueRepositoryResolver();
      BLEHandshakeService.clearCoordinatorFactoryResolver();
      BLEMessageHandlerFacade.clearDependencyResolvers();
      BLEMessageHandlerFacadeImpl.clearDependencyResolvers();
      BLEServiceFacade.clearHandshakeServiceRegistrar();
      await di_service_locator.resetServiceLocator();
    } catch (e) {
      debugPrint('Warning: Service locator reset error: $e');
    }
  }

  static Future<void> completeCleanup() async {
    await cleanupDatabase();
    resetSharedPreferences();
  }

  static T getService<T extends Object>() => GetIt.instance<T>();

  static String readProjectFile(String relativePath) {
    final file = File(relativePath);
    if (!file.existsSync()) {
      throw FileSystemException('File not found', relativePath);
    }
    return file.readAsStringSync();
  }

  static void _configureDefaultDependenciesFromLocator(GetIt locator) {
    if (locator.isRegistered<IPreferencesRepository>()) {
      final preferencesRepository = locator<IPreferencesRepository>();
      MessageRouter.configureDependencyResolvers(
        preferencesRepositoryResolver: () => preferencesRepository,
      );
    }

    if (locator.isRegistered<IContactRepository>() &&
        locator.isRegistered<IMessageRepository>()) {
      ContactManagementService.configureDependencyResolvers(
        contactRepositoryResolver: () => locator<IContactRepository>(),
        messageRepositoryResolver: () => locator<IMessageRepository>(),
      );
      SecurityManager.configureContactRepositoryResolver(
        () => locator<IContactRepository>(),
      );
    }

    if (locator.isRegistered<IArchiveRepository>()) {
      ArchiveManagementService.configureArchiveRepositoryResolver(
        () => locator<IArchiveRepository>(),
      );
      ArchiveSearchService.configureArchiveRepositoryResolver(
        () => locator<IArchiveRepository>(),
      );
    }

    if (locator.isRegistered<IChatsRepository>() &&
        locator.isRegistered<IMessageRepository>() &&
        locator.isRegistered<IArchiveRepository>()) {
      ChatManagementService.configureDependencyResolvers(
        chatsRepositoryResolver: () => locator<IChatsRepository>(),
        messageRepositoryResolver: () => locator<IMessageRepository>(),
        archiveRepositoryResolver: () => locator<IArchiveRepository>(),
      );
    }

    if (locator.isRegistered<IRepositoryProvider>()) {
      final repositoryProvider = locator<IRepositoryProvider>();
      OfflineMessageQueue.configureDefaultRepositoryProvider(
        repositoryProvider,
      );
      HintScannerService.configureRepositoryProvider(repositoryProvider);
      HandshakeCoordinator.configureRepositoryProviderResolver(
        () => repositoryProvider,
      );
      SmartHandshakeManager.configureRepositoryProviderResolver(
        () => repositoryProvider,
      );
      MeshRelayEngine.configureDependencyResolvers(
        repositoryProviderResolver: () => repositoryProvider,
      );
    }

    if (locator.isRegistered<ISeenMessageStore>()) {
      final seenMessageStore = locator<ISeenMessageStore>();
      MeshRelayEngine.configureDependencyResolvers(
        seenMessageStoreResolver: () => seenMessageStore,
      );
    }

    if (locator.isRegistered<IConnectionService>()) {
      final connectionService = locator<IConnectionService>();
      MeshRelayEngine.configureDependencyResolvers(
        persistentIdResolver: () => connectionService.myPersistentId,
      );
    }

    if (locator.isRegistered<IDatabaseProvider>()) {
      final databaseProvider = locator<IDatabaseProvider>();
      MessageQueueRepository.configureDefaultDatabaseProvider(databaseProvider);
      QueuePersistenceManager.configureDefaultDatabaseProvider(
        databaseProvider,
      );
    }
  }

  static void _registerAppServicesSnapshot(
    GetIt locator, {
    IConnectionService? preferredConnectionService,
    IMeshNetworkingService? preferredMeshNetworkingService,
    ISecurityService? preferredSecurityService,
  }) {
    final hasRequiredCoreBindings =
        locator.isRegistered<IContactRepository>() &&
        locator.isRegistered<IMessageRepository>() &&
        locator.isRegistered<IArchiveRepository>() &&
        locator.isRegistered<IChatsRepository>() &&
        locator.isRegistered<IUserPreferences>() &&
        locator.isRegistered<IPreferencesRepository>() &&
        locator.isRegistered<IRepositoryProvider>() &&
        locator.isRegistered<ISharedMessageQueueProvider>();

    if (!hasRequiredCoreBindings) {
      if (locator.isRegistered<AppServices>()) {
        locator.unregister<AppServices>();
      }
      return;
    }

    final connectionService =
        preferredConnectionService ??
        (locator.isRegistered<IConnectionService>()
            ? locator<IConnectionService>()
            : MockConnectionService());

    final meshNetworkingService =
        preferredMeshNetworkingService ??
        (locator.isRegistered<IMeshNetworkingService>()
            ? locator<IMeshNetworkingService>()
            : _NoopMeshNetworkingService());

    final securityService =
        preferredSecurityService ??
        (locator.isRegistered<ISecurityService>()
            ? locator<ISecurityService>()
            : const _NoopSecurityService());

    final meshHealthMonitor = _resolveMeshHealthMonitor(
      locator: locator,
      meshNetworkingService: meshNetworkingService,
    );

    if (!locator.isRegistered<MeshNetworkHealthMonitor>()) {
      locator.registerSingleton<MeshNetworkHealthMonitor>(meshHealthMonitor);
    }

    final snapshot = AppServices(
      contactRepository: locator<IContactRepository>(),
      messageRepository: locator<IMessageRepository>(),
      archiveRepository: locator<IArchiveRepository>(),
      chatsRepository: locator<IChatsRepository>(),
      userPreferences: locator<IUserPreferences>(),
      preferencesRepository: locator<IPreferencesRepository>(),
      repositoryProvider: locator<IRepositoryProvider>(),
      sharedMessageQueueProvider: locator<ISharedMessageQueueProvider>(),
      connectionService: connectionService,
      meshNetworkingService: meshNetworkingService,
      meshNetworkHealthMonitor: meshHealthMonitor,
      securityService: securityService,
    );

    if (locator.isRegistered<AppServices>()) {
      locator.unregister<AppServices>();
    }
    locator.registerSingleton<AppServices>(snapshot);
  }

  static MeshNetworkHealthMonitor _resolveMeshHealthMonitor({
    required GetIt locator,
    required IMeshNetworkingService meshNetworkingService,
  }) {
    if (locator.isRegistered<MeshNetworkHealthMonitor>()) {
      return locator<MeshNetworkHealthMonitor>();
    }
    if (meshNetworkingService case MeshNetworkingService service) {
      return service.healthMonitor;
    }
    if (meshNetworkingService case _NoopMeshNetworkingService service) {
      return service.healthMonitor;
    }
    return MeshNetworkHealthMonitor();
  }

  static String _sanitize(String input) =>
      input.replaceAll(RegExp('[^a-zA-Z0-9_]'), '_');
}

class _NoopSecurityService implements ISecurityService {
  const _NoopSecurityService();

  @override
  void registerIdentityMapping({
    required String persistentPublicKey,
    required String ephemeralID,
  }) {}

  @override
  void unregisterIdentityMapping(String persistentPublicKey) {}

  @override
  Future<SecurityLevel> getCurrentLevel(
    String publicKey, [
    IContactRepository? repo,
  ]) async => SecurityLevel.low;

  @override
  Future<EncryptionMethod> getEncryptionMethod(
    String publicKey,
    IContactRepository repo,
  ) async => EncryptionMethod.global();

  @override
  Future<String> encryptMessage(
    String message,
    String publicKey,
    IContactRepository repo,
  ) async => message;

  @override
  Future<String> decryptMessage(
    String encryptedMessage,
    String publicKey,
    IContactRepository repo,
  ) async => encryptedMessage;

  @override
  Future<Uint8List> encryptBinaryPayload(
    Uint8List data,
    String publicKey,
    IContactRepository repo,
  ) async => data;

  @override
  Future<Uint8List> decryptBinaryPayload(
    Uint8List data,
    String publicKey,
    IContactRepository repo,
  ) async => data;

  @override
  bool hasEstablishedNoiseSession(String peerSessionId) => false;
}

class _NoopMeshNetworkingService implements IMeshNetworkingService {
  final MeshNetworkHealthMonitor healthMonitor = MeshNetworkHealthMonitor();

  @override
  Stream<MeshNetworkStatus> get meshStatus => healthMonitor.meshStatus;

  @override
  Stream<RelayStatistics> get relayStats => healthMonitor.relayStats;

  @override
  Stream<QueueSyncManagerStats> get queueStats => healthMonitor.queueStats;

  @override
  Stream<String> get messageDeliveryStream =>
      healthMonitor.messageDeliveryStream;

  @override
  Stream<ReceivedBinaryEvent> get binaryPayloadStream => const Stream.empty();

  @override
  Future<void> initialize({String? nodeId}) async {
    healthMonitor.broadcastFallbackStatus(currentNodeId: nodeId ?? 'test-node');
  }

  @override
  void dispose() {
    healthMonitor.dispose();
  }

  @override
  Future<MeshSendResult> sendMeshMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async => MeshSendResult.error('Mesh runtime unavailable in test harness');

  @override
  Future<String> sendBinaryMedia({
    required Uint8List data,
    required String recipientId,
    int originalType = BinaryPayloadType.media,
    Map<String, dynamic>? metadata,
  }) async => 'noop-transfer';

  @override
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  }) async => false;

  @override
  Future<Map<String, QueueSyncResult>> syncQueuesWithPeers() async => const {};

  @override
  Future<bool> retryMessage(String messageId) async => false;

  @override
  Future<bool> removeMessage(String messageId) async => false;

  @override
  Future<bool> setPriority(String messageId, MessagePriority priority) async =>
      false;

  @override
  Future<int> retryAllMessages() async => 0;

  @override
  List<QueuedMessage> getQueuedMessagesForChat(String chatId) => const [];

  @override
  List<PendingBinaryTransfer> getPendingBinaryTransfers() => const [];

  @override
  MeshNetworkStatistics getNetworkStatistics() => const MeshNetworkStatistics(
    nodeId: 'test-node',
    isInitialized: false,
    relayStatistics: null,
    queueStatistics: null,
    syncStatistics: null,
    spamStatistics: null,
    spamPreventionActive: false,
    queueSyncActive: false,
  );

  @override
  void refreshMeshStatus() {
    healthMonitor.broadcastFallbackStatus(currentNodeId: 'test-node');
  }
}

// Adapters allow interface-only overrides to satisfy concrete lookups without losing shared state.
class _MessageRepositoryAdapter extends MessageRepository {
  _MessageRepositoryAdapter(this._delegate);

  final IMessageRepository _delegate;

  @override
  Future<void> clearMessages(ChatId chatId) => _delegate.clearMessages(chatId);

  @override
  Future<bool> deleteMessage(MessageId messageId) =>
      _delegate.deleteMessage(messageId);

  @override
  Future<List<Message>> getAllMessages() => _delegate.getAllMessages();

  @override
  Future<Message?> getMessageById(MessageId messageId) =>
      _delegate.getMessageById(messageId);

  @override
  Future<List<Message>> getMessages(ChatId chatId) =>
      _delegate.getMessages(chatId);

  @override
  Future<List<Message>> getMessagesForContact(String publicKey) =>
      _delegate.getMessagesForContact(publicKey);

  @override
  Future<void> migrateChatId(ChatId oldChatId, ChatId newChatId) =>
      _delegate.migrateChatId(oldChatId, newChatId);

  @override
  Future<void> saveMessage(Message message) => _delegate.saveMessage(message);

  @override
  Future<void> updateMessage(Message message) =>
      _delegate.updateMessage(message);
}

class _ContactRepositoryAdapter extends ContactRepository {
  _ContactRepositoryAdapter(this._delegate);

  final IContactRepository _delegate;

  @override
  Future<void> cacheSharedSecret(String publicKey, String sharedSecret) =>
      _delegate.cacheSharedSecret(publicKey, sharedSecret);

  @override
  Future<Uint8List?> getCachedSharedSeedBytes(String publicKey) =>
      _delegate.getCachedSharedSeedBytes(publicKey);

  @override
  Future<String?> getCachedSharedSecret(String publicKey) =>
      _delegate.getCachedSharedSecret(publicKey);

  @override
  Future<void> cacheSharedSeedBytes(String publicKey, Uint8List seedBytes) =>
      _delegate.cacheSharedSeedBytes(publicKey, seedBytes);

  @override
  Future<void> clearCachedSecrets(String publicKey) =>
      _delegate.clearCachedSecrets(publicKey);

  @override
  Future<bool> deleteContact(String publicKey) =>
      _delegate.deleteContact(publicKey);

  @override
  Future<Contact?> getContact(String publicKey) =>
      _delegate.getContact(publicKey);

  @override
  Future<Contact?> getContactByAnyId(String identifier) =>
      _delegate.getContactByAnyId(identifier);

  @override
  Future<Contact?> getContactByCurrentEphemeralId(String ephemeralId) =>
      _delegate.getContactByCurrentEphemeralId(ephemeralId);

  @override
  Future<Contact?> getContactByPersistentKey(String persistentPublicKey) =>
      _delegate.getContactByPersistentKey(persistentPublicKey);

  @override
  Future<Contact?> getContactByPersistentUserId(UserId persistentPublicKey) =>
      _delegate.getContactByPersistentUserId(persistentPublicKey);

  @override
  Future<Contact?> getContactByUserId(UserId userId) =>
      _delegate.getContactByUserId(userId);

  @override
  Future<Map<String, Contact>> getAllContacts() => _delegate.getAllContacts();

  @override
  Future<void> markContactVerified(String publicKey) =>
      _delegate.markContactVerified(publicKey);

  @override
  Future<void> saveContact(String publicKey, String displayName) =>
      _delegate.saveContact(publicKey, displayName);

  @override
  Future<void> saveContactWithSecurity(
    String publicKey,
    String displayName,
    SecurityLevel securityLevel, {
    String? currentEphemeralId,
    String? persistentPublicKey,
  }) => _delegate.saveContactWithSecurity(
    publicKey,
    displayName,
    securityLevel,
    currentEphemeralId: currentEphemeralId,
    persistentPublicKey: persistentPublicKey,
  );

  @override
  Future<void> updateContactEphemeralId(
    String publicKey,
    String newEphemeralId,
  ) => _delegate.updateContactEphemeralId(publicKey, newEphemeralId);

  @override
  Future<void> updateContactSecurityLevel(
    String publicKey,
    SecurityLevel newLevel,
  ) => _delegate.updateContactSecurityLevel(publicKey, newLevel);

  @override
  Future<void> updateNoiseSession({
    required String publicKey,
    required String noisePublicKey,
    required String sessionState,
  }) => _delegate.updateNoiseSession(
    publicKey: publicKey,
    noisePublicKey: noisePublicKey,
    sessionState: sessionState,
  );

  @override
  Future<SecurityLevel> getContactSecurityLevel(String publicKey) =>
      _delegate.getContactSecurityLevel(publicKey);

  @override
  Future<void> downgradeSecurityForDeletedContact(
    String publicKey,
    String reason,
  ) => _delegate.downgradeSecurityForDeletedContact(publicKey, reason);

  @override
  Future<bool> upgradeContactSecurity(
    String publicKey,
    SecurityLevel newLevel,
  ) => _delegate.upgradeContactSecurity(publicKey, newLevel);

  @override
  Future<bool> resetContactSecurity(String publicKey, String reason) =>
      _delegate.resetContactSecurity(publicKey, reason);

  @override
  Future<String?> getContactName(String publicKey) =>
      _delegate.getContactName(publicKey);

  @override
  Future<int> getContactCount() => _delegate.getContactCount();

  @override
  Future<int> getVerifiedContactCount() => _delegate.getVerifiedContactCount();

  @override
  Future<Map<SecurityLevel, int>> getContactsBySecurityLevel() =>
      _delegate.getContactsBySecurityLevel();

  @override
  Future<int> getRecentlyActiveContactCount() =>
      _delegate.getRecentlyActiveContactCount();

  @override
  Future<void> markContactFavorite(String publicKey) =>
      _delegate.markContactFavorite(publicKey);

  @override
  Future<void> unmarkContactFavorite(String publicKey) =>
      _delegate.unmarkContactFavorite(publicKey);

  @override
  Future<bool> toggleContactFavorite(String publicKey) =>
      _delegate.toggleContactFavorite(publicKey);

  @override
  Future<List<Contact>> getFavoriteContacts() =>
      _delegate.getFavoriteContacts();

  @override
  Future<int> getFavoriteContactCount() => _delegate.getFavoriteContactCount();

  @override
  Future<bool> isContactFavorite(String publicKey) =>
      _delegate.isContactFavorite(publicKey);
}
