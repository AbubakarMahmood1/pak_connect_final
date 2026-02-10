// Shared test harness utilities for pak_connect tests

import 'package:flutter/foundation.dart' show debugPrint;
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/di/service_locator.dart' as di_service_locator;
import 'package:pak_connect/core/di/repository_provider_impl.dart';
import 'package:pak_connect/core/interfaces/i_archive_repository.dart';
import 'package:pak_connect/core/interfaces/i_chats_repository.dart';
import 'package:pak_connect/core/interfaces/i_connection_service.dart';
import 'package:pak_connect/core/interfaces/i_contact_repository.dart';
import 'package:pak_connect/core/interfaces/i_database_provider.dart';
import 'package:pak_connect/core/interfaces/i_message_repository.dart';
import 'package:pak_connect/core/interfaces/i_repository_provider.dart';
import 'package:pak_connect/core/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/core/networking/topology_manager.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/data/database/database_encryption.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/data/services/seen_message_store.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqflite.dart' as sqflite_common;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pak_connect/core/power/battery_optimizer.dart';

import 'ble/fake_ble_platform.dart';
import 'mocks/in_memory_secure_storage.dart';
import 'mocks/mock_flutter_secure_storage.dart';
import 'mocks/mock_contact_repository.dart';
import 'mocks/mock_message_repository.dart';
import 'sqlite/native_sqlite_loader.dart';

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
    await di_service_locator.setupServiceLocator();

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

  static String _sanitize(String input) =>
      input.replaceAll(RegExp('[^a-zA-Z0-9_]'), '_');
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
