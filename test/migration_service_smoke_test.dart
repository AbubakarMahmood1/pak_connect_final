import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/database/migration_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'migration_service_smoke',
    );
  });

  setUp(() async {
    await TestSetup.configureTestDatabase(label: 'migration_service_smoke');
    TestSetup.resetSharedPreferences();
  });

  tearDown(() async {
    await TestSetup.nukeDatabase();
  });

  test('MigrationService migrates legacy SharedPreferences data', () async {
    SharedPreferences.setMockInitialValues(_buildMockPrefs());

    final result = await MigrationService.migrate();

    expect(result.success, isTrue);
    expect(result.migrationCounts['contacts'], equals(1));
    expect(result.migrationCounts['messages'], equals(1));
    expect(result.migrationCounts['chats'], equals(1));

    final db = await DatabaseHelper.database;
    final contacts = await db.query('contacts');
    final chats = await db.query('chats');
    final messages = await db.query('messages');
    final offlineQueue = await db.query('offline_message_queue');

    expect(contacts.length, equals(1));
    expect(chats.length, equals(1));
    expect(messages.length, equals(1));
    expect(offlineQueue.length, equals(1));
  });
}

Map<String, Object> _buildMockPrefs() {
  final now = DateTime.now().millisecondsSinceEpoch;
  final chatId = 'pk_alice';

  return {
    'enhanced_contacts_v2': [
      jsonEncode({
        'publicKey': 'pk_alice',
        'displayName': 'Alice Example',
        'trustStatus': 1,
        'securityLevel': 2,
        'firstSeen': now - 1000,
        'lastSeen': now,
        'lastSecuritySync': now,
      }),
    ],
    'chat_messages': [
      jsonEncode({
        'id': 'msg_1',
        'chatId': chatId,
        'content': 'Hello from legacy storage',
        'timestamp': now,
        'isFromMe': true,
        'status': 1,
      }),
    ],
    'offline_message_queue_v2': [
      jsonEncode({
        'id': 'msg_queued_1',
        'chatId': chatId,
        'content': 'Queued message content',
        'recipientPublicKey': 'pk_alice',
        'senderPublicKey': 'pk_me',
        'queuedAt': now,
        'attempts': 1,
        'maxRetries': 3,
        'priority': 1,
        'status': 0,
        'isRelayMessage': false,
      }),
    ],
    'deleted_message_ids_v1': ['legacy_deleted_msg'],
    'device_public_key_mapping': 'DEVICE123:pk_alice',
    'contact_last_seen': 'pk_alice:$now',
    'chat_unread_counts': '$chatId:2',
    'username': 'LegacyUser',
    'device_id': 'legacy-device',
    'app_version': '2.0.0',
  };
}
