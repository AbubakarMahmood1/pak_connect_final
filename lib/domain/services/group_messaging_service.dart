// Local broadcast-list service: one ordinary encrypted direct message is
// queued per selected contact. Recipients see a 1:1 message; this is not a
// shared group-conversation protocol.

import 'package:logging/logging.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';

import '../models/contact_group.dart';
// For MessagePriority
import '../interfaces/i_contact_repository.dart';
import '../interfaces/i_group_repository.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import '../values/id_types.dart';

/// Service for managing local broadcast lists via secure multi-unicast.
///
/// Architecture:
/// - NO shared group keys (each message encrypted individually per recipient)
/// - Every recipient enters the ordinary direct-message queue
/// - Noise encryption and transport happen later in the normal 1:1 send path
/// - Per-recipient queue acceptance/failure is recorded locally for the sender
///
/// Message flow:
/// 1. User sends to group
/// 2. Service queues N ordinary direct messages (N = list size)
/// 3. The direct-message pipeline encrypts/sends each message independently
/// 4. Queue acceptance is tracked independently per recipient
///
/// The legacy Group* names match the persisted schema. They must not be used
/// to claim recipient-side group history, membership sync, or shared replies.
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

  /// Queue one ordinary direct message for every recipient in a local list.
  ///
  /// Returns the sender-local GroupMessage immediately, with queue submission
  /// continuing asynchronously for each recipient.
  ///
  /// Delivery tracking:
  /// - pending: Queue submission has not completed
  /// - sent: Accepted by the direct-message queue (legacy persisted name)
  /// - delivered: Reserved for a future correlated receipt integration
  /// - failed: Contact lookup or queue submission failed
  Future<GroupMessage> sendGroupMessage({
    required String groupId,
    required String senderKey,
    required String content,
  }) async {
    _logger.info('📤 Queueing broadcast for local list $groupId');

    try {
      // Get group
      final group = await _groupRepo.getGroup(groupId);
      if (group == null) {
        throw Exception('Group not found: $groupId');
      }

      // Create the sender-local dispatch record (legacy GroupMessage name).
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

      // Queue to each member asynchronously (fire and forget).
      _sendToMembers(message, group);

      return message;
    } catch (e) {
      _logger.severe('❌ Failed to queue broadcast: $e');
      rethrow;
    }
  }

  /// Submit the content to the direct-message queue for every list recipient.
  ///
  /// This runs asynchronously and records whether each queue submission was
  /// accepted. It does not observe BLE delivery acknowledgements.
  Future<void> _sendToMembers(GroupMessage message, ContactGroup group) async {
    _logger.info('📡 Sending to ${message.deliveryStatus.length} members...');

    int accepted = 0;
    int failed = 0;

    for (final memberKey in message.deliveryStatus.keys) {
      try {
        // Get contact to find chat ID
        final contact = await _contactRepo.getContactByAnyId(memberKey);
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

        // Queue an ordinary 1:1 message. The normal direct-message pipeline
        // handles Noise and retries later.
        final recipientIdentity = contact.chatId;
        await _messageQueue.queueMessage(
          chatId: recipientIdentity,
          content: message.content,
          recipientPublicKey: recipientIdentity,
          senderPublicKey: message.senderKey,
          priority: MessagePriority.normal,
        );

        // The persisted enum name is retained for schema compatibility; at
        // this boundary it means accepted by the offline queue, not delivered.
        await _updateStatus(
          MessageId(message.id),
          memberKey,
          MessageDeliveryStatus.sent,
        );

        accepted++;

        _logger.fine('  ✅ Queued direct message for ${contact.displayName}');
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
      '✅ Broadcast queue submission complete: $accepted accepted, $failed failed',
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

  /// Dormant integration seam for a future correlated direct-message receipt.
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
