// Repository for contact groups with SQLite persistence
// Handles CRUD operations for groups, members, messages, and delivery status

import 'package:logging/logging.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../../core/interfaces/i_group_repository.dart';
import '../database/database_helper.dart';
import '../../core/models/contact_group.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

/// Repository for managing contact groups in SQLite
///
/// Provides:
/// - Group CRUD operations
/// - Member management
/// - Message storage with per-member delivery tracking
/// - Transaction safety for multi-table operations
class GroupRepository implements IGroupRepository {
  static final _logger = Logger('GroupRepository');

  /// Create a new contact group
  ///
  /// Atomically creates group and adds members in a single transaction.
  /// Returns the created group with generated ID.
  @override
  Future<ContactGroup> createGroup(ContactGroup group) async {
    final db = await DatabaseHelper.database;

    try {
      await db.transaction((txn) async {
        // Insert group
        await txn.insert('contact_groups', {
          'id': group.id,
          'name': group.name,
          'description': group.description,
          'created_at': group.created.millisecondsSinceEpoch,
          'last_modified_at': group.lastModified.millisecondsSinceEpoch,
        });

        // Insert members
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final memberKey in group.memberKeys) {
          await txn.insert('group_members', {
            'group_id': group.id,
            'member_key': memberKey,
            'added_at': now,
          });
        }

        _logger.info(
          '✅ Created group ${group.name} with ${group.memberCount} members',
        );
      });

      return group;
    } catch (e) {
      _logger.severe('❌ Failed to create group: $e');
      rethrow;
    }
  }

  /// Get a group by ID
  @override
  Future<ContactGroup?> getGroup(String groupId) async {
    final db = await DatabaseHelper.database;

    try {
      // Get group metadata
      final groupResults = await db.query(
        'contact_groups',
        where: 'id = ?',
        whereArgs: [groupId],
      );

      if (groupResults.isEmpty) {
        return null;
      }

      final groupData = groupResults.first;

      // Get members
      final memberResults = await db.query(
        'group_members',
        columns: ['member_key'],
        where: 'group_id = ?',
        whereArgs: [groupId],
      );

      final memberKeys = memberResults
          .map((row) => row['member_key'] as String)
          .toList();

      return ContactGroup(
        id: groupData['id'] as String,
        name: groupData['name'] as String,
        memberKeys: memberKeys,
        description: groupData['description'] as String?,
        created: DateTime.fromMillisecondsSinceEpoch(
          groupData['created_at'] as int,
        ),
        lastModified: DateTime.fromMillisecondsSinceEpoch(
          groupData['last_modified_at'] as int,
        ),
      );
    } catch (e) {
      _logger.severe('❌ Failed to get group $groupId: $e');
      rethrow;
    }
  }

  /// Get all groups
  @override
  Future<List<ContactGroup>> getAllGroups() async {
    final db = await DatabaseHelper.database;

    try {
      final groupResults = await db.query(
        'contact_groups',
        orderBy: 'last_modified_at DESC',
      );

      final groups = <ContactGroup>[];
      for (final groupData in groupResults) {
        final groupId = groupData['id'] as String;

        // Get members for this group
        final memberResults = await db.query(
          'group_members',
          columns: ['member_key'],
          where: 'group_id = ?',
          whereArgs: [groupId],
        );

        final memberKeys = memberResults
            .map((row) => row['member_key'] as String)
            .toList();

        groups.add(
          ContactGroup(
            id: groupId,
            name: groupData['name'] as String,
            memberKeys: memberKeys,
            description: groupData['description'] as String?,
            created: DateTime.fromMillisecondsSinceEpoch(
              groupData['created_at'] as int,
            ),
            lastModified: DateTime.fromMillisecondsSinceEpoch(
              groupData['last_modified_at'] as int,
            ),
          ),
        );
      }

      return groups;
    } catch (e) {
      _logger.severe('❌ Failed to get all groups: $e');
      rethrow;
    }
  }

  /// Update a group (name, description, members)
  ///
  /// Replaces members atomically - removes old members and adds new ones
  /// in a single transaction.
  @override
  Future<void> updateGroup(ContactGroup group) async {
    final db = await DatabaseHelper.database;

    try {
      await db.transaction((txn) async {
        // Update group metadata
        await txn.update(
          'contact_groups',
          {
            'name': group.name,
            'description': group.description,
            'last_modified_at': group.lastModified.millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [group.id],
        );

        // Replace members: delete old + insert new
        await txn.delete(
          'group_members',
          where: 'group_id = ?',
          whereArgs: [group.id],
        );

        final now = DateTime.now().millisecondsSinceEpoch;
        for (final memberKey in group.memberKeys) {
          await txn.insert('group_members', {
            'group_id': group.id,
            'member_key': memberKey,
            'added_at': now,
          });
        }

        _logger.info('✅ Updated group ${group.name}');
      });
    } catch (e) {
      _logger.severe('❌ Failed to update group ${group.id}: $e');
      rethrow;
    }
  }

  /// Delete a group
  ///
  /// CASCADE delete automatically removes:
  /// - group_members (FK constraint)
  /// - group_messages (FK constraint)
  /// - group_message_delivery (FK constraint on messages)
  @override
  Future<void> deleteGroup(String groupId) async {
    final db = await DatabaseHelper.database;

    try {
      final count = await db.delete(
        'contact_groups',
        where: 'id = ?',
        whereArgs: [groupId],
      );

      if (count > 0) {
        _logger.info(
          '✅ Deleted group $groupId (CASCADE removed members + messages)',
        );
      }
    } catch (e) {
      _logger.severe('❌ Failed to delete group $groupId: $e');
      rethrow;
    }
  }

  /// Save a group message with initial delivery status
  ///
  /// Creates message record + delivery tracking records for all members
  /// (excluding sender) in a single transaction.
  @override
  Future<void> saveGroupMessage(GroupMessage message) async {
    final db = await DatabaseHelper.database;

    try {
      await db.transaction((txn) async {
        // Insert message
        await txn.insert('group_messages', {
          'id': message.id,
          'group_id': message.groupId,
          'sender_key': message.senderKey,
          'content': message.content,
          'timestamp': message.timestamp.millisecondsSinceEpoch,
        });

        // Insert delivery status for each member (except sender)
        for (final entry in message.deliveryStatus.entries) {
          await txn.insert('group_message_delivery', {
            'message_id': message.id,
            'member_key': entry.key,
            'status': entry.value.index,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });
        }

        _logger.info(
          '✅ Saved group message ${message.id.shortId()}... with ${message.deliveryStatus.length} delivery records',
        );
      });
    } catch (e) {
      _logger.severe('❌ Failed to save group message ${message.id}: $e');
      rethrow;
    }
  }

  /// Update delivery status for a specific member
  @override
  Future<void> updateDeliveryStatus(
    String messageId,
    String memberKey,
    MessageDeliveryStatus status,
  ) async {
    final db = await DatabaseHelper.database;

    try {
      await db.update(
        'group_message_delivery',
        {
          'status': status.index,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'message_id = ? AND member_key = ?',
        whereArgs: [messageId, memberKey],
      );

      _logger.fine(
        'Updated delivery status for $messageId -> $memberKey: $status',
      );
    } catch (e) {
      _logger.severe('❌ Failed to update delivery status: $e');
      rethrow;
    }
  }

  /// Get messages for a group
  @override
  Future<List<GroupMessage>> getGroupMessages(
    String groupId, {
    int limit = 50,
  }) async {
    final db = await DatabaseHelper.database;

    try {
      final messageResults = await db.query(
        'group_messages',
        where: 'group_id = ?',
        whereArgs: [groupId],
        orderBy: 'timestamp DESC',
        limit: limit,
      );

      final messages = <GroupMessage>[];
      for (final msgData in messageResults) {
        final messageId = msgData['id'] as String;

        // Get delivery status for this message
        final deliveryResults = await db.query(
          'group_message_delivery',
          where: 'message_id = ?',
          whereArgs: [messageId],
        );

        final deliveryStatus = <String, MessageDeliveryStatus>{};
        for (final delivery in deliveryResults) {
          final memberKey = delivery['member_key'] as String;
          final statusIndex = delivery['status'] as int;
          deliveryStatus[memberKey] = MessageDeliveryStatus.values[statusIndex];
        }

        messages.add(
          GroupMessage(
            id: messageId,
            groupId: msgData['group_id'] as String,
            senderKey: msgData['sender_key'] as String,
            content: msgData['content'] as String,
            timestamp: DateTime.fromMillisecondsSinceEpoch(
              msgData['timestamp'] as int,
            ),
            deliveryStatus: deliveryStatus,
          ),
        );
      }

      return messages;
    } catch (e) {
      _logger.severe('❌ Failed to get messages for group $groupId: $e');
      rethrow;
    }
  }

  /// Get a specific message with delivery status
  @override
  Future<GroupMessage?> getMessage(String messageId) async {
    final db = await DatabaseHelper.database;

    try {
      final messageResults = await db.query(
        'group_messages',
        where: 'id = ?',
        whereArgs: [messageId],
      );

      if (messageResults.isEmpty) {
        return null;
      }

      final msgData = messageResults.first;

      // Get delivery status
      final deliveryResults = await db.query(
        'group_message_delivery',
        where: 'message_id = ?',
        whereArgs: [messageId],
      );

      final deliveryStatus = <String, MessageDeliveryStatus>{};
      for (final delivery in deliveryResults) {
        final memberKey = delivery['member_key'] as String;
        final statusIndex = delivery['status'] as int;
        deliveryStatus[memberKey] = MessageDeliveryStatus.values[statusIndex];
      }

      return GroupMessage(
        id: messageId,
        groupId: msgData['group_id'] as String,
        senderKey: msgData['sender_key'] as String,
        content: msgData['content'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          msgData['timestamp'] as int,
        ),
        deliveryStatus: deliveryStatus,
      );
    } catch (e) {
      _logger.severe('❌ Failed to get message $messageId: $e');
      rethrow;
    }
  }

  /// Get groups that contain a specific member
  @override
  Future<List<ContactGroup>> getGroupsForMember(String memberKey) async {
    final db = await DatabaseHelper.database;

    try {
      // Find group IDs that have this member
      final memberResults = await db.query(
        'group_members',
        columns: ['group_id'],
        where: 'member_key = ?',
        whereArgs: [memberKey],
      );

      final groupIds = memberResults
          .map((row) => row['group_id'] as String)
          .toList();

      if (groupIds.isEmpty) {
        return [];
      }

      // Get full group data for each ID
      final groups = <ContactGroup>[];
      for (final groupId in groupIds) {
        final group = await getGroup(groupId);
        if (group != null) {
          groups.add(group);
        }
      }

      return groups;
    } catch (e) {
      _logger.severe('❌ Failed to get groups for member $memberKey: $e');
      rethrow;
    }
  }

  /// Get statistics for debugging
  @override
  Future<Map<String, int>> getStatistics() async {
    final db = await DatabaseHelper.database;

    try {
      final groupCount =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM contact_groups'),
          ) ??
          0;

      final memberCount =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM group_members'),
          ) ??
          0;

      final messageCount =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM group_messages'),
          ) ??
          0;

      return {
        'groups': groupCount,
        'members': memberCount,
        'messages': messageCount,
      };
    } catch (e) {
      _logger.severe('❌ Failed to get statistics: $e');
      return {'groups': 0, 'members': 0, 'messages': 0};
    }
  }
}
