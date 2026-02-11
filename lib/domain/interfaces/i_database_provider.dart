import 'package:sqflite_sqlcipher/sqflite.dart';

/// Domain contract for resolving the encrypted SQLite database instance.
abstract interface class IDatabaseProvider {
  Future<Database> get database;

  /// Returns database file size information used by settings/profile UI.
  Future<Map<String, dynamic>> getDatabaseSize();
}
