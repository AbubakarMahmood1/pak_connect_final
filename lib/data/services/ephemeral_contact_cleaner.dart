import 'package:logging/logging.dart';
import '../repositories/contact_repository.dart';
import '../repositories/message_repository.dart';
import 'package:pak_connect/domain/utils/chat_utils.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';

/// Cleans up ephemeral contacts with no chat history (called on disconnect)
class EphemeralContactCleaner {
  static OfflineMessageQueueContract? Function()? _queueResolver;

  static void configureQueueResolver(
    OfflineMessageQueueContract? Function() resolver,
  ) {
    _queueResolver = resolver;
  }

  static void clearQueueResolver() {
    _queueResolver = null;
  }

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
      final resolver = _queueResolver;
      if (resolver == null) {
        logger.warning(
          'Shared queue unavailable during contact cleanup - keeping contact',
        );
        return true;
      }

      final queue = resolver();
      if (queue == null) {
        logger.warning(
          'Shared queue unavailable during contact cleanup - keeping contact',
        );
        return true;
      }
      final keys = <String>{
        contact.publicKey,
        if (contact.persistentPublicKey?.isNotEmpty == true)
          contact.persistentPublicKey!,
        if (contact.currentEphemeralId?.isNotEmpty == true)
          contact.currentEphemeralId!,
      };

      final queued =
          <QueuedMessage>[
            ...queue.getMessagesByStatus(QueuedMessageStatus.pending),
            ...queue.getMessagesByStatus(QueuedMessageStatus.sending),
            ...queue.getMessagesByStatus(QueuedMessageStatus.awaitingAck),
            ...queue.getMessagesByStatus(QueuedMessageStatus.retrying),
          ].where((m) {
            final keyMatch = keys.contains(m.recipientPublicKey);
            return keyMatch;
          });

      final count = queued.length;
      if (count > 0) {
        logger.info(
          '⏳ Skipping cleanup for ${contact.displayName} — $count queued message(s) still pending',
        );
        return true;
      }
    } catch (e) {
      logger.warning(
        'Queue lookup failed while cleaning ${contact.displayName}; '
        'keeping contact: $e',
      );
      return true;
    }
    return false;
  }
}
