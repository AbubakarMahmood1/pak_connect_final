// Shared test harness utilities for pak_connect tests

import 'dart:io';
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
import 'package:pak_connect/data/database/database_encryption.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/database/database_provider.dart';
import 'package:pak_connect/data/repositories/archive_repository.dart';
import 'package:pak_connect/data/repositories/chats_repository.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/data/services/seen_message_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqflite.dart' as sqflite_common;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pak_connect/core/power/battery_optimizer.dart';

import 'ble/fake_ble_platform.dart';
import 'mocks/in_memory_secure_storage.dart';
import 'mocks/mock_flutter_secure_storage.dart';
import 'mocks/mock_contact_repository.dart';
import 'mocks/mock_message_repository.dart';
import 'mocks/mock_connection_service.dart';
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

    if (configureDiWithMocks &&
        [
          contactRepository,
          messageRepository,
          seenMessageStore,
          connectionService,
          chatsRepository,
          archiveRepository,
        ].any((element) => element != null)) {
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
      // ignore: avoid_print
      print('${record.level.name}: ${record.message}');
    });
  }

  static Future<void> configureTestDatabase({String? label}) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final sanitized = _sanitize(label ?? 'suite');
    final dbName = 'pak_connect_test_${sanitized}_${timestamp}.db';
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
    if (resetGraph) {
      await resetDIServiceLocator();
      await di_service_locator.setupServiceLocator();
    }

    void override<T extends Object>(T instance) {
      if (locator.isRegistered<T>()) {
        locator.unregister<T>();
      }
      locator.registerSingleton<T>(instance);
    }

    if (contactRepository != null) {
      override<IContactRepository>(contactRepository);
      if (contactRepository is ContactRepository) {
        override<ContactRepository>(contactRepository);
      }
    }
    if (messageRepository != null) {
      override<IMessageRepository>(messageRepository);
      if (messageRepository is MessageRepository) {
        override<MessageRepository>(messageRepository);
      }
    }
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

    // If repositories were overridden, update repository provider to use them.
    if (contactRepository != null || messageRepository != null) {
      final contactRepo = locator<IContactRepository>();
      final messageRepo = locator<IMessageRepository>();
      override<IRepositoryProvider>(
        RepositoryProviderImpl(
          contactRepository: contactRepo,
          messageRepository: messageRepo,
        ),
      );
    }
  }

  static Future<void> cleanupDatabase() async {
    try {
      await DatabaseHelper.close();
      await DatabaseHelper.deleteDatabase();
    } catch (e) {
      // ignore: avoid_print
      print('Warning: Database cleanup error: $e');
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
      // ignore: avoid_print
      print('Warning: Database nuke error: $e');
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
      // ignore: avoid_print
      print('Warning: Full database reset error: $e');
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
      // ignore: avoid_print
      print('Warning: Service locator reset error: $e');
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
