import 'package:sqflite_sqlcipher/sqflite.dart';

import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'database_helper.dart';

/// Default SQLCipher-backed database provider wired through DI.
class DatabaseProvider implements IDatabaseProvider {
  @override
  Future<Database> get database => DatabaseHelper.database;

  @override
  Future<Map<String, dynamic>> getDatabaseSize() =>
      DatabaseHelper.getDatabaseSize();
}
