import 'package:sqflite_sqlcipher/sqflite.dart';

/// Abstraction for providing the encrypted SQLite database instance.
abstract interface class IDatabaseProvider {
  Future<Database> get database;
}
