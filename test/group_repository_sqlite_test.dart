import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/repositories/group_repository.dart';
import 'package:pak_connect/domain/models/contact_group.dart';

import 'test_helpers/test_setup.dart';

ContactGroup _group({
  required String id,
  required String name,
  required List<String> members,
  String? description,
  DateTime? created,
  DateTime? lastModified,
}) {
  final now = DateTime.now();
  return ContactGroup(
    id: id,
    name: name,
    memberKeys: members,
    description: description,
    created: created ?? now,
    lastModified: lastModified ?? now,
  );
}

GroupMessage _groupMessage({
  required String id,
  required String groupId,
  required DateTime timestamp,
  required Map<String, MessageDeliveryStatus> deliveryStatus,
}) {
  return GroupMessage(
    id: id,
    groupId: groupId,
    senderKey: 'sender-key',
    content: 'hello-$id',
    timestamp: timestamp,
    deliveryStatus: deliveryStatus,
  );
}

void main() {
  late List<LogRecord> logRecords;
  late Set<String> allowedSevere;

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'group_repository_sqlite');
  });

  setUp(() async {
    logRecords = <LogRecord>[];
    allowedSevere = <String>{};
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    await TestSetup.fullDatabaseReset();
  });

  tearDown(() {
    final severeErrors = logRecords
        .where((log) => log.level >= Level.SEVERE)
        .where(
          (log) =>
              !allowedSevere.any((pattern) => log.message.contains(pattern)),
        )
        .toList();
    expect(
      severeErrors,
      isEmpty,
      reason:
          'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
    );
  });

  tearDownAll(() async {
    await DatabaseHelper.deleteDatabase();
  });

  group('GroupRepository SQLite', () {
    test('createGroup + getGroup persists members and metadata', () async {
      final repo = GroupRepository();
      final group = _group(
        id: 'grp-1',
        name: 'Friends',
        members: const ['alice', 'bob'],
        description: 'close contacts',
        created: DateTime(2026, 1, 1, 10),
        lastModified: DateTime(2026, 1, 1, 11),
      );

      final created = await repo.createGroup(group);
      final fetched = await repo.getGroup('grp-1');

      expect(created.id, 'grp-1');
      expect(fetched, isNotNull);
      expect(fetched!.name, 'Friends');
      expect(fetched.description, 'close contacts');
      expect(fetched.memberKeys, containsAll(<String>['alice', 'bob']));
      expect(fetched.memberKeys.length, 2);
    });

    test('getGroup returns null for missing group', () async {
      final repo = GroupRepository();
      final group = await repo.getGroup('does-not-exist');
      expect(group, isNull);
    });

    test('getAllGroups returns latest modified first', () async {
      final repo = GroupRepository();

      await repo.createGroup(
        _group(
          id: 'grp-old',
          name: 'Old',
          members: const ['a'],
          lastModified: DateTime(2026, 1, 1, 9),
        ),
      );
      await repo.createGroup(
        _group(
          id: 'grp-new',
          name: 'New',
          members: const ['b'],
          lastModified: DateTime(2026, 1, 1, 12),
        ),
      );

      final groups = await repo.getAllGroups();

      expect(groups.length, 2);
      expect(groups.first.id, 'grp-new');
      expect(groups.last.id, 'grp-old');
    });

    test('updateGroup replaces member set and updates metadata', () async {
      final repo = GroupRepository();
      await repo.createGroup(
        _group(
          id: 'grp-2',
          name: 'Team',
          members: const ['alice', 'bob'],
          description: 'v1',
          lastModified: DateTime(2026, 1, 2, 10),
        ),
      );

      await repo.updateGroup(
        _group(
          id: 'grp-2',
          name: 'Team Updated',
          members: const ['bob', 'charlie'],
          description: 'v2',
          created: DateTime(2026, 1, 2, 9),
          lastModified: DateTime(2026, 1, 2, 11),
        ),
      );

      final updated = await repo.getGroup('grp-2');

      expect(updated, isNotNull);
      expect(updated!.name, 'Team Updated');
      expect(updated.description, 'v2');
      expect(updated.memberKeys, containsAll(<String>['bob', 'charlie']));
      expect(updated.memberKeys, isNot(contains('alice')));
      expect(updated.memberKeys.length, 2);
    });

    test('message save/update/get/list and limit work with delivery states', () async {
      final repo = GroupRepository();
      await repo.createGroup(
        _group(
          id: 'grp-msg',
          name: 'Message Group',
          members: const ['alice', 'bob', 'charlie'],
        ),
      );

      final older = _groupMessage(
        id: 'msg-older',
        groupId: 'grp-msg',
        timestamp: DateTime(2026, 1, 1, 8),
        deliveryStatus: const {
          'alice': MessageDeliveryStatus.sent,
          'bob': MessageDeliveryStatus.failed,
        },
      );
      final newer = _groupMessage(
        id: 'msg-newer',
        groupId: 'grp-msg',
        timestamp: DateTime(2026, 1, 1, 9),
        deliveryStatus: const {
          'alice': MessageDeliveryStatus.pending,
          'charlie': MessageDeliveryStatus.sent,
        },
      );

      await repo.saveGroupMessage(older);
      await repo.saveGroupMessage(newer);
      await repo.updateDeliveryStatus(
        'msg-newer',
        'alice',
        MessageDeliveryStatus.delivered,
      );

      final fetched = await repo.getMessage('msg-newer');
      final list = await repo.getGroupMessages('grp-msg');
      final limited = await repo.getGroupMessages('grp-msg', limit: 1);

      expect(fetched, isNotNull);
      expect(
        fetched!.deliveryStatus['alice'],
        MessageDeliveryStatus.delivered,
      );
      expect(fetched.deliveryStatus['charlie'], MessageDeliveryStatus.sent);

      expect(list.length, 2);
      expect(list.first.id, 'msg-newer');
      expect(list.last.id, 'msg-older');
      expect(limited.length, 1);
      expect(limited.first.id, 'msg-newer');
    });

    test('getMessage returns null for unknown message id', () async {
      final repo = GroupRepository();
      final message = await repo.getMessage('missing-message');
      expect(message, isNull);
    });

    test('deleteGroup cascades member/message/delivery rows', () async {
      final repo = GroupRepository();
      await repo.createGroup(
        _group(id: 'grp-del', name: 'To Delete', members: const ['a', 'b']),
      );
      await repo.saveGroupMessage(
        _groupMessage(
          id: 'msg-del',
          groupId: 'grp-del',
          timestamp: DateTime(2026, 1, 1, 10),
          deliveryStatus: const {
            'a': MessageDeliveryStatus.sent,
            'b': MessageDeliveryStatus.sent,
          },
        ),
      );

      await repo.deleteGroup('grp-del');

      final db = await DatabaseHelper.database;
      final groups = await db.query(
        'contact_groups',
        where: 'id = ?',
        whereArgs: ['grp-del'],
      );
      final members = await db.query(
        'group_members',
        where: 'group_id = ?',
        whereArgs: ['grp-del'],
      );
      final messages = await db.query(
        'group_messages',
        where: 'group_id = ?',
        whereArgs: ['grp-del'],
      );
      final deliveries = await db.query(
        'group_message_delivery',
        where: 'message_id = ?',
        whereArgs: ['msg-del'],
      );

      expect(groups, isEmpty);
      expect(members, isEmpty);
      expect(messages, isEmpty);
      expect(deliveries, isEmpty);
    });

    test('getGroupsForMember returns only matching groups', () async {
      final repo = GroupRepository();
      await repo.createGroup(
        _group(
          id: 'grp-a',
          name: 'A',
          members: const ['target', 'alice'],
        ),
      );
      await repo.createGroup(
        _group(
          id: 'grp-b',
          name: 'B',
          members: const ['target', 'bob'],
        ),
      );
      await repo.createGroup(
        _group(
          id: 'grp-c',
          name: 'C',
          members: const ['charlie'],
        ),
      );

      final groups = await repo.getGroupsForMember('target');
      final missing = await repo.getGroupsForMember('nobody');

      expect(groups.length, 2);
      expect(groups.map((g) => g.id), containsAll(<String>['grp-a', 'grp-b']));
      expect(missing, isEmpty);
    });

    test('getStatistics reports counts for groups/members/messages', () async {
      final repo = GroupRepository();
      await repo.createGroup(
        _group(id: 'grp-s1', name: 'S1', members: const ['a', 'b']),
      );
      await repo.createGroup(
        _group(id: 'grp-s2', name: 'S2', members: const ['a']),
      );
      await repo.saveGroupMessage(
        _groupMessage(
          id: 'msg-s1',
          groupId: 'grp-s1',
          timestamp: DateTime(2026, 1, 1, 10),
          deliveryStatus: const {'a': MessageDeliveryStatus.sent},
        ),
      );
      await repo.saveGroupMessage(
        _groupMessage(
          id: 'msg-s2',
          groupId: 'grp-s2',
          timestamp: DateTime(2026, 1, 1, 11),
          deliveryStatus: const {'a': MessageDeliveryStatus.sent},
        ),
      );

      final stats = await repo.getStatistics();

      expect(stats['groups'], 2);
      expect(stats['members'], 3);
      expect(stats['messages'], 2);
    });
  });
}
