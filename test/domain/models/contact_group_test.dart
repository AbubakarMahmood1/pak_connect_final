import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/models/contact_group.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  group('ContactGroup', () {
    test('create initializes immutable members and generated id', () {
      final group = ContactGroup.create(
        name: 'Friends',
        memberKeys: const <String>['alice', 'bob'],
        description: 'Trusted contacts',
      );

      expect(group.id, startsWith('grp_'));
      expect(group.idValue, ChatId(group.id));
      expect(group.name, 'Friends');
      expect(group.description, 'Trusted contacts');
      expect(group.memberCount, 2);
      expect(group.hasMember('alice'), isTrue);
      expect(group.hasMember('charlie'), isFalse);
      expect(group.memberKeys, const <String>['alice', 'bob']);
      expect(() => group.memberKeys.add('charlie'), throwsUnsupportedError);
    });

    test('copyWith updates selected fields while preserving id/created', () {
      final original = ContactGroup(
        id: 'grp_fixed',
        name: 'Original',
        memberKeys: const <String>['alice'],
        description: 'desc',
        created: DateTime.utc(2026, 1, 1),
        lastModified: DateTime.utc(2026, 1, 1),
      );

      final updated = original.copyWith(
        name: 'Updated',
        memberKeys: const <String>['alice', 'bob'],
        description: 'updated',
      );

      expect(updated.id, original.id);
      expect(updated.created, original.created);
      expect(updated.name, 'Updated');
      expect(updated.description, 'updated');
      expect(updated.memberKeys, const <String>['alice', 'bob']);
      expect(() => updated.memberKeys.add('charlie'), throwsUnsupportedError);
      expect(updated.lastModified.isAfter(original.lastModified), isTrue);
    });

    test('toJson/fromJson and equality contract', () {
      final created = DateTime.utc(2026, 2, 3, 4, 5, 6);
      final lastModified = DateTime.utc(2026, 2, 4, 5, 6, 7);
      final group = ContactGroup(
        id: 'grp_same',
        name: 'RoundTrip',
        memberKeys: const <String>['a', 'b'],
        description: null,
        created: created,
        lastModified: lastModified,
      );

      final json = group.toJson();
      final restored = ContactGroup.fromJson(json);
      final withSameId = ContactGroup(
        id: 'grp_same',
        name: 'Different',
        memberKeys: const <String>['x'],
        description: 'different',
        created: created,
        lastModified: lastModified,
      );

      expect(restored.id, group.id);
      expect(restored.name, group.name);
      expect(restored.memberKeys, group.memberKeys);
      expect(
        restored.created.millisecondsSinceEpoch,
        group.created.millisecondsSinceEpoch,
      );
      expect(
        restored.lastModified.millisecondsSinceEpoch,
        group.lastModified.millisecondsSinceEpoch,
      );
      expect(group == withSameId, isTrue);
      expect(group.hashCode, withSameId.hashCode);
      expect(group.toString(), contains('members: 2'));
    });
  });

  group('MessageDeliveryStatusExtension', () {
    test('maps enum values to display names', () {
      expect(MessageDeliveryStatus.pending.displayName, 'Pending');
      expect(MessageDeliveryStatus.sent.displayName, 'Sent');
      expect(MessageDeliveryStatus.delivered.displayName, 'Delivered');
      expect(MessageDeliveryStatus.failed.displayName, 'Failed');
    });
  });

  group('GroupMessage', () {
    test(
      'create excludes sender from delivery map and initializes pending statuses',
      () {
        final message = GroupMessage.create(
          groupId: 'grp_a',
          senderKey: 'alice',
          content: 'hello team',
          memberKeys: const <String>['alice', 'bob', 'charlie'],
        );

        expect(message.id, startsWith('gm_'));
        expect(message.groupId, 'grp_a');
        expect(message.groupIdValue, const ChatId('grp_a'));
        expect(message.senderKey, 'alice');
        expect(message.deliveryStatus.containsKey('alice'), isFalse);
        expect(message.deliveryStatus['bob'], MessageDeliveryStatus.pending);
        expect(
          message.deliveryStatus['charlie'],
          MessageDeliveryStatus.pending,
        );
        expect(message.idValue, MessageId(message.id));
      },
    );

    test('updateDeliveryStatus returns new instance with updated map', () {
      final base = GroupMessage(
        id: 'gm_1',
        groupId: 'grp_1',
        senderKey: 'alice',
        content: 'content',
        timestamp: DateTime.utc(2026, 1, 1),
        deliveryStatus: const <String, MessageDeliveryStatus>{
          'bob': MessageDeliveryStatus.pending,
          'charlie': MessageDeliveryStatus.sent,
        },
      );

      final updated = base.updateDeliveryStatus(
        'bob',
        MessageDeliveryStatus.delivered,
      );

      expect(updated.id, base.id);
      expect(updated.groupId, base.groupId);
      expect(updated.senderKey, base.senderKey);
      expect(updated.deliveryStatus['bob'], MessageDeliveryStatus.delivered);
      expect(base.deliveryStatus['bob'], MessageDeliveryStatus.pending);
    });

    test('delivery metrics and status helpers behave correctly', () {
      final message = GroupMessage(
        id: 'gm_2',
        groupId: 'grp_2',
        senderKey: 'sender',
        content: 'payload',
        timestamp: DateTime.utc(2026, 1, 2),
        deliveryStatus: const <String, MessageDeliveryStatus>{
          'a': MessageDeliveryStatus.delivered,
          'b': MessageDeliveryStatus.failed,
          'c': MessageDeliveryStatus.delivered,
        },
      );

      expect(message.deliveryProgress, closeTo(2 / 3, 0.0001));
      expect(message.isFullyDelivered, isFalse);
      expect(message.hasFailures, isTrue);
      expect(message.deliveredCount, 2);
      expect(message.failedCount, 1);

      final selfOnly = GroupMessage(
        id: 'gm_3',
        groupId: 'grp_3',
        senderKey: 'sender',
        content: 'self',
        timestamp: DateTime.utc(2026, 1, 2),
        deliveryStatus: const <String, MessageDeliveryStatus>{},
      );
      expect(selfOnly.deliveryProgress, 1.0);
      expect(selfOnly.isFullyDelivered, isTrue);
      expect(selfOnly.hasFailures, isFalse);
      expect(selfOnly.deliveredCount, 0);
      expect(selfOnly.failedCount, 0);
    });

    test('toJson/fromJson and equality contract', () {
      final message = GroupMessage(
        id: 'gm_fixed',
        groupId: 'grp_fixed',
        senderKey: 'sender_key',
        content: 'serialized',
        timestamp: DateTime.utc(2026, 3, 1, 10, 30),
        deliveryStatus: const <String, MessageDeliveryStatus>{
          'bob': MessageDeliveryStatus.sent,
          'eve': MessageDeliveryStatus.delivered,
        },
      );

      final json = message.toJson();
      final restored = GroupMessage.fromJson(json);
      final sameIdDifferentPayload = GroupMessage(
        id: 'gm_fixed',
        groupId: 'grp_other',
        senderKey: 'other_sender',
        content: 'different',
        timestamp: DateTime.utc(2026, 1, 1),
        deliveryStatus: const <String, MessageDeliveryStatus>{},
      );

      expect(restored.id, message.id);
      expect(restored.groupId, message.groupId);
      expect(restored.senderKey, message.senderKey);
      expect(restored.content, message.content);
      expect(
        restored.timestamp.millisecondsSinceEpoch,
        message.timestamp.millisecondsSinceEpoch,
      );
      expect(restored.deliveryStatus, message.deliveryStatus);
      expect(restored == sameIdDifferentPayload, isTrue);
      expect(restored.hashCode, sameIdDifferentPayload.hashCode);
      expect(restored.toString(), contains('delivered:'));
    });
  });
}
