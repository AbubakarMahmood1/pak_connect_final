import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_migration_runner.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

class _RecordingDatabase implements sqlcipher.Database {
  final executedSql = <String>[];

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    executedSql.add(sql);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final logRecords = <LogRecord>[];

  setUp(() {
    logRecords.clear();
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
  });

  group('DatabaseMigrationRunner', () {
    test('runs all migrations from v1 to v10', () async {
      final db = _RecordingDatabase();
      final logger = Logger('migration_full');

      await DatabaseMigrationRunner.runMigrations(db, 1, 10, logger: logger);

      expect(
        db.executedSql.any(
          (sql) => sql.contains('CREATE TABLE app_preferences'),
        ),
        isTrue,
      );
      expect(
        db.executedSql.any(
          (sql) =>
              sql.contains('ALTER TABLE contacts ADD COLUMN noise_public_key'),
        ),
        isTrue,
      );
      expect(
        db.executedSql.any(
          (sql) => sql.contains('CREATE TABLE contact_groups'),
        ),
        isTrue,
      );
      expect(
        db.executedSql.any((sql) => sql.contains('CREATE TABLE seen_messages')),
        isTrue,
      );

      expect(
        logRecords.any(
          (log) => log.message.contains('Migration to v10 complete'),
        ),
        isTrue,
      );
      expect(
        logRecords.any(
          (log) => log.message.contains('Migration to v4 complete'),
        ),
        isTrue,
      );
    });

    test('runs only pending migrations when starting from v9', () async {
      final db = _RecordingDatabase();
      final logger = Logger('migration_incremental');

      await DatabaseMigrationRunner.runMigrations(db, 9, 10, logger: logger);

      expect(
        db.executedSql.any((sql) => sql.contains('CREATE TABLE seen_messages')),
        isTrue,
      );

      expect(
        db.executedSql.any(
          (sql) => sql.contains('CREATE TABLE app_preferences'),
        ),
        isFalse,
      );
      expect(
        db.executedSql.any(
          (sql) => sql.contains('CREATE TABLE contact_groups'),
        ),
        isFalse,
      );
      expect(
        db.executedSql.any(
          (sql) =>
              sql.contains('ALTER TABLE contacts ADD COLUMN noise_public_key'),
        ),
        isFalse,
      );
    });
  });
}
