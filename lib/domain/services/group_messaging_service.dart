// Service for sending group messages via multi-unicast (one encrypted message per member)
// Uses existing Noise sessions - no shared passwords, no group keys

import 'package:logging/logging.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';

import '../models/contact_group.dart';
// For MessagePriority
import '../interfaces/i_contact_repository.dart';
import '../interfaces/i_group_repository.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import '../values/id_types.dart';

/// Service for managing group messaging via secure multi-unicast
///
/// Architecture:
/// - NO shared group keys (each message encrypted individually per recipient)
/// - Uses existing Noise sessions (same security as 1-to-1 messaging)
/// - Automatic fallback to offline queue if member offline
/// - Per-member delivery tracking
///
/// Message flow:
/// 1. User sends to group
/// 2. Service sends N individual encrypted messages (N = group size)
/// 3. Each message uses recipient's Noise session
/// 4. Delivery status tracked independently per member
class GroupMessagingService {
  static final _logger = Logger('GroupMessagingService');

  final IGroupRepository _groupRepo;
  final IContactRepository _contactRepo;
  final OfflineMessageQueueContract _messageQueue;

  GroupMessagingService({
    required IGroupRepository groupRepo,
    required IContactRepository contactRepo,
    required OfflineMessageQueueContract messageQueue,
  }) : _groupRepo = groupRepo,
       _contactRepo = contactRepo,
       _messageQueue = messageQueue;

  /// Send a message to a group
  ///
  /// Returns the created GroupMessage with initial delivery status.
  /// Messages are sent asynchronously to each member via their individual Noise sessions.
  ///
  /// Delivery tracking:
  /// - pending: Message queued but not sent yet
  /// - sent: Message sent via Noise session (may not be delivered yet)
  /// - delivered: Confirmed delivered (requires future delivery receipt support)
  /// - failed: Send failed (member offline, no session, etc.)
  Future<GroupMessage> sendGroupMessage({
    required String groupId,
    required String senderKey,
    required String content,
  }) async {
    _logger.info('📤 Sending group message to group $groupId');

    try {
      // Get group
      final group = await _groupRepo.getGroup(groupId);
      if (group == null) {
        throw Exception('Group not found: $groupId');
      }

      // Create group message
      final message = GroupMessage.create(
        groupId: groupId,
        senderKey: senderKey,
        content: content,
        memberKeys: group.memberKeys,
      );

      // Save to repository immediately with pending status
      await _groupRepo.saveGroupMessage(message);
      _logger.info(
        '  Created message ${message.id.shortId()}... for ${message.deliveryStatus.length} recipients',
      );

      // Send to each member asynchronously (fire and forget)
      // Delivery status will be updated via callbacks
      _sendToMembers(message, group);

      return message;
    } catch (e) {
      _logger.severe('❌ Failed to send group message: $e');
      rethrow;
    }
  }

  /// Send message to all group members individually
  ///
  /// This runs asynchronously and updates delivery status as each send completes.
  /// Uses the offline message queue for automatic retry if member is offline.
  Future<void> _sendToMembers(GroupMessage message, ContactGroup group) async {
    _logger.info('📡 Sending to ${message.deliveryStatus.length} members...');

    int sent = 0;
    int queued = 0;
    int failed = 0;

    for (final memberKey in message.deliveryStatus.keys) {
      try {
        // Get contact to find chat ID
        final contact = await _contactRepo.getContact(memberKey);
        if (contact == null) {
          _logger.warning('  ⚠️ Member $memberKey not in contacts - skipping');
          await _updateStatus(
            MessageId(message.id),
            memberKey,
            MessageDeliveryStatus.failed,
          );
          failed++;
          continue;
        }

        // Queue message for this member (uses existing offline queue + Noise sessions)
        final chatId = 'chat_${contact.publicKey}';
        await _messageQueue.queueMessage(
          chatId: chatId,
          content: message.content,
          recipientPublicKey: memberKey,
          senderPublicKey: message.senderKey,
          priority: MessagePriority.normal,
        );

        // Update status to sent (queue will handle delivery)
        await _updateStatus(
          MessageId(message.id),
          memberKey,
          MessageDeliveryStatus.sent,
        );

        // Note: In future, we could track which messages were queued vs sent immediately
        // For now, we mark as "sent" once queued
        queued++;
        sent++;

        _logger.fine('  ✅ Queued for ${contact.displayName}');
      } catch (e) {
        _logger.warning('  ❌ Failed to send to $memberKey: $e');
        await _updateStatus(
          MessageId(message.id),
          memberKey,
          MessageDeliveryStatus.failed,
        );
        failed++;
      }
    }

    _logger.info(
      '✅ Group send complete: $sent sent, $queued queued, $failed failed',
    );
  }

  /// Update delivery status for a member
  Future<void> _updateStatus(
    MessageId messageId,
    String memberKey,
    MessageDeliveryStatus status,
  ) async {
    try {
      await _groupRepo.updateDeliveryStatus(messageId.value, memberKey, status);
    } catch (e) {
      _logger.warning('Failed to update delivery status: $e');
      // Non-critical - don't rethrow
    }
  }

  /// Get messages for a group
  Future<List<GroupMessage>> getGroupMessages(
    String groupId, {
    int limit = 50,
  }) async {
    return await _groupRepo.getGroupMessages(groupId, limit: limit);
  }

  /// Get a specific message with current delivery status
  Future<GroupMessage?> getMessage(MessageId messageId) async {
    return await _groupRepo.getMessage(messageId.value);
  }

  /// Mark message as delivered for a specific member
  ///
  /// Called when delivery receipt is received (future enhancement).
  Future<void> markDelivered(MessageId messageId, String memberKey) async {
    _logger.info('✅ Message ${messageId.value} delivered to $memberKey');
    await _updateStatus(messageId, memberKey, MessageDeliveryStatus.delivered);
  }

  Future<void> markDeliveredForMember(MessageId messageId, ChatId memberId) =>
      markDelivered(messageId, memberId.value);

  /// Mark message as failed for a specific member
  ///
  /// Called when send permanently fails (no session, max retries exceeded, etc.)
  Future<void> markFailed(MessageId messageId, String memberKey) async {
    _logger.warning('❌ Message ${messageId.value} failed for $memberKey');
    await _updateStatus(messageId, memberKey, MessageDeliveryStatus.failed);
  }

  Future<void> markFailedForMember(MessageId messageId, ChatId memberId) =>
      markFailed(messageId, memberId.value);

  /// Get delivery summary for a message
  ///
  /// Returns counts of messages in each status.
  Future<Map<MessageDeliveryStatus, int>> getDeliverySummary(
    MessageId messageId,
  ) async {
    final message = await getMessage(messageId);
    if (message == null) {
      return {};
    }

    final summary = <MessageDeliveryStatus, int>{};
    for (final status in message.deliveryStatus.values) {
      summary[status] = (summary[status] ?? 0) + 1;
    }

    return summary;
  }
}
