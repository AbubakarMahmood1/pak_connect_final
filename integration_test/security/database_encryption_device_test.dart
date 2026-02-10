import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('DB Encryption (device)', () {
    testWidgets(
      'database is not plaintext SQLite and cannot be queried without password',
      (_) async {
        if (!(Platform.isAndroid || Platform.isIOS)) {
          // This proof test is intended for real Android/iOS integration runs.
          return;
        }

        final db = await DatabaseHelper.database;
        final now = DateTime.now().millisecondsSinceEpoch;
        await db.insert(
          'app_preferences',
          {
            'key': 'security_test_marker',
            'value': 'sensitive-value-$now',
            'value_type': 'string',
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: sqlcipher.ConflictAlgorithm.replace,
        );

        final dbPath = await DatabaseHelper.getDatabasePath();
        final dbFile = File(dbPath);
        expect(await dbFile.exists(), isTrue);

        // Plain SQLite files start with "SQLite format 3".
        final headerBytes = await dbFile.openRead(0, 16).first;
        final header = String.fromCharCodes(headerBytes.take(15));
        expect(
          header,
          isNot(equals('SQLite format 3')),
          reason:
              'Encrypted SQLCipher DB must not expose plaintext SQLite header',
        );

        // Important: close the encrypted singleton first, then probe with a
        // fresh non-singleton no-password connection to avoid handle reuse.
        await DatabaseHelper.close();

        var queriedWithoutPassword = false;
        try {
          final plaintextOpen = await sqlcipher.databaseFactory.openDatabase(
            dbPath,
            options: sqlcipher.OpenDatabaseOptions(
              readOnly: true,
              singleInstance: false,
            ),
          );
          try {
            await plaintextOpen.rawQuery('SELECT COUNT(*) FROM sqlite_master');
            queriedWithoutPassword = true;
          } finally {
            await plaintextOpen.close();
          }
        } catch (_) {
          // Expected on encrypted DBs.
        }

        expect(
          queriedWithoutPassword,
          isFalse,
          reason:
              'DB must not be queryable without SQLCipher password on device',
        );

        final verified = await DatabaseHelper.verifyEncryption();
        expect(verified, isTrue);
      },
    );
  });
}
