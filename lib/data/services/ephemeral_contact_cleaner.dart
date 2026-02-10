import 'package:logging/logging.dart';
import '../repositories/contact_repository.dart';
import '../repositories/message_repository.dart';
import '../../core/utils/chat_utils.dart';
import '../../core/services/message_queue_repository.dart';
import '../../domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/values/id_types.dart';

/// Cleans up ephemeral contacts with no chat history (called on disconnect)
class EphemeralContactCleaner {
  static Future<void> cleanup({
    required String contactId,
    required Logger logger,
  }) async {
    try {
      logger.info(
        '🧹 Checking if contact needs cleanup: ${contactId.length > 8 ? '${contactId.substring(0, 8)}...' : contactId}',
      );

      final contactRepo = ContactRepository();
      final messageRepo = MessageRepository();

      final contact = await contactRepo.getContact(contactId);
      if (contact == null) {
        logger.fine('Contact not found - nothing to cleanup');
        return;
      }

      if (contact.trustStatus == TrustStatus.verified) {
        logger.fine('Contact is verified - keeping');
        return;
      }

      final chatId = ChatUtils.generateChatId(contactId);
      final messages = await messageRepo.getMessages(ChatId(chatId));

      final hasPendingQueueMessages = await _hasPendingQueuedMessages(
        contact: contact,
        logger: logger,
      );

      if (messages.isEmpty && !hasPendingQueueMessages) {
        final deleted = await contactRepo.deleteContact(contactId);
        if (deleted) {
          logger.info(
            '✅ Deleted orphaned ephemeral contact: ${contact.displayName}',
          );
        } else {
          logger.fine('Contact delete returned false (already removed?)');
        }
      } else {
        logger.fine(
          'Contact has ${messages.length} saved message(s) or pending queue items - keeping',
        );
      }
    } catch (e) {
      logger.warning('Failed to cleanup ephemeral contact: $e');
    }
  }

  /// Avoid deleting a temp contact if there are queued/pending messages for it.
  static Future<bool> _hasPendingQueuedMessages({
    required Contact contact,
    required Logger logger,
  }) async {
    try {
      final repo = MessageQueueRepository();
      await repo.loadQueueFromStorage();
      final keys = <String>{
        contact.publicKey,
        if (contact.persistentPublicKey?.isNotEmpty == true)
          contact.persistentPublicKey!,
        if (contact.currentEphemeralId?.isNotEmpty == true)
          contact.currentEphemeralId!,
      };

      final queued = repo.getAllMessages().where((m) {
        final keyMatch = keys.contains(m.recipientPublicKey);
        final status = m.status;
        final isPending =
            status == QueuedMessageStatus.pending ||
            status == QueuedMessageStatus.sending ||
            status == QueuedMessageStatus.awaitingAck ||
            status == QueuedMessageStatus.retrying;
        return keyMatch && isPending;
      });

      final count = queued.length;
      if (count > 0) {
        logger.info(
          '⏳ Skipping cleanup for ${contact.displayName} — $count queued message(s) still pending',
        );
        return true;
      }
    } catch (e) {
      logger.fine(
        'Queue lookup failed while cleaning ${contact.displayName}: $e',
      );
    }
    return false;
  }
}
