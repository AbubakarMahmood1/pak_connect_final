// Standard test environment setup for pak_connect tests
//
// This file provides utilities to properly initialize the test environment
// with consistent mocking and setup across all test files.

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/networking/topology_manager.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqflite.dart' as sqflite_common;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'ble/fake_ble_platform.dart';
import 'mocks/in_memory_secure_storage.dart';
import 'sqlite/native_sqlite_loader.dart';

/// Standard test environment setup for pak_connect tests
class TestSetup {
  /// Initialize the test environment with all required mocks and setup
  ///
  /// Uses a unique database name for each test run to avoid file locking issues.
  /// Call this in `setUpAll()` for every test file:
  /// ```dart
  /// setUpAll(() async {
  ///   await TestSetup.initializeTestEnvironment();
  /// });
  /// ```
  static Future<void> initializeTestEnvironment() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    // Prevent platform channel lookups for BLE managers inside flutter test.
    FakeBlePlatform.ensureRegistered();

    // Provide a deterministic secure-storage backend before any plugin code
    FlutterSecureStoragePlatform.instance = InMemorySecureStorage();

    // Use unique database name for each test run to avoid file locking issues
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    DatabaseHelper.setTestDatabaseName('pak_connect_test_$timestamp.db');
    final rawNodeId = 'test-node-$timestamp';
    final topologyManager = TopologyManager.instance;
    final paddedNodeId = rawNodeId.length >= 8
        ? rawNodeId
        : rawNodeId.padRight(8, '0');
    topologyManager.initializeForTests(paddedNodeId);

    // Ensure sqlite3 dynamic library is resolvable in sandboxed environments
    NativeSqliteLoader.ensureInitialized();

    // Initialize sqflite_ffi for database tests, forcing the loader inside isolates
    sqfliteFfiInit();
    final sqliteFactory = createDatabaseFactoryFfi(
      ffiInit: NativeSqliteLoader.ensureInitialized,
    );
    sqflite_common.databaseFactory = sqliteFactory;

    // Initialize SharedPreferences with empty state and isolated cache
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});

    // Configure logging to reduce noise and avoid conflicts
    setupTestLogging();
  }

  /// Configure logging for tests to avoid stream controller conflicts
  ///
  /// Sets logging to WARNING level and uses simple print() to avoid
  /// recursive logger.info() calls that cause "Cannot fire new event" errors.
  static void setupTestLogging({Level level = Level.WARNING}) {
    Logger.root.level = level;

    // Remove any existing listeners to avoid conflicts
    Logger.root.clearListeners();

    // Use simple print() to avoid logger stream controller conflicts
    Logger.root.onRecord.listen((record) {
      // ignore: avoid_print
      print('${record.level.name}: ${record.message}');
    });
  }

  /// Clean up the database between tests
  ///
  /// Call this in `setUp()` or `tearDown()` to ensure test isolation:
  /// ```dart
  /// setUp(() async {
  ///   await TestSetup.cleanupDatabase();
  /// });
  /// ```
  static Future<void> cleanupDatabase() async {
    try {
      await DatabaseHelper.close();
      await DatabaseHelper.deleteDatabase();
    } catch (e) {
      // Ignore errors during cleanup
      // ignore: avoid_print
      print('Warning: Database cleanup error (may be expected): $e');
    }
  }

  /// Nuclear option: Delete all table data without closing database
  ///
  /// Use this when you need to clear data but keep the database open.
  /// More aggressive than cleanupDatabase() but doesn't recreate the database.
  /// ```dart
  /// setUp(() async {
  ///   await TestSetup.nukeDatabase();
  /// });
  /// ```
  static Future<void> nukeDatabase() async {
    try {
      final db = await DatabaseHelper.database;

      // Disable foreign key constraints for cleanup
      await db.execute('PRAGMA foreign_keys = OFF');

      // Get all user tables (exclude sqlite internal tables)
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
      );

      // Delete all data from each table
      for (final table in tables) {
        final tableName = table['name'] as String;
        try {
          await db.delete(tableName);
        } catch (e) {
          // ignore: avoid_print
          print('Warning: Failed to clear table $tableName: $e');
        }
      }

      // Re-enable foreign key constraints
      await db.execute('PRAGMA foreign_keys = ON');
    } catch (e) {
      // ignore: avoid_print
      print('Warning: Database nuke error: $e');
    }
  }

  /// Complete database reset - nuclear option that forces schema recreation
  ///
  /// Most thorough cleanup option. Use this when test isolation is critical.
  /// Uses PRAGMA writable_schema to bypass corruption and force clean state.
  /// ```dart
  /// setUp(() async {
  ///   await TestSetup.fullDatabaseReset();
  /// });
  /// ```
  static Future<void> fullDatabaseReset() async {
    try {
      // Close any existing connection
      await DatabaseHelper.close();

      // Get fresh connection
      final db = await DatabaseHelper.database;

      // Nuclear option: Use writable_schema to forcibly clean corrupted schema
      await db.execute('PRAGMA writable_schema = ON');
      await db.execute('PRAGMA foreign_keys = OFF');

      // Delete ALL entries from sqlite_master except SQLite internals
      // This includes tables, indices, triggers, views
      try {
        await db.execute(
          "DELETE FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
        );
      } catch (e) {
        // ignore: avoid_print
        print('Warning: Failed to clear sqlite_master: $e');
      }

      await db.execute('PRAGMA writable_schema = OFF');

      // Reset user_version to 0 to force onCreate() to run
      await db.execute('PRAGMA user_version = 0');

      // VACUUM to rebuild the database file and fix internal corruption
      try {
        await db.execute('VACUUM');
      } catch (e) {
        // ignore: avoid_print
        print('Warning: VACUUM failed: $e');
      }

      // Close and reopen to trigger schema recreation via onCreate()
      await DatabaseHelper.close();

      // Reopen database - this will trigger onCreate() since user_version = 0
      final freshDb = await DatabaseHelper.database;

      await freshDb.execute('PRAGMA foreign_keys = ON');

      // Verify tables exist now
      final tables = await freshDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
      );

      // ignore: avoid_print
      print('✅ Database reset complete. Tables: ${tables.length}');
    } catch (e) {
      // ignore: avoid_print
      print('Warning: Full database reset error: $e');
    }
  }

  /// Reset SharedPreferences to empty state
  ///
  /// Call this in `setUp()` if your test modifies SharedPreferences:
  /// ```dart
  /// setUp(() async {
  ///   TestSetup.resetSharedPreferences();
  /// });
  /// ```
  static void resetSharedPreferences() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
  }

  /// Complete cleanup - database + SharedPreferences
  ///
  /// Call this in `tearDown()` for comprehensive cleanup:
  /// ```dart
  /// tearDown(() async {
  ///   await TestSetup.completeCleanup();
  /// });
  /// ```
  static Future<void> completeCleanup() async {
    await cleanupDatabase();
    resetSharedPreferences();
  }
}
