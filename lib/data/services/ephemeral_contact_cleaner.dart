import 'package:logging/logging.dart';
import '../repositories/contact_repository.dart';
import '../repositories/message_repository.dart';
import '../../core/utils/chat_utils.dart';
import '../../domain/entities/contact.dart';
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

      if (messages.isEmpty) {
        final deleted = await contactRepo.deleteContact(contactId);
        if (deleted) {
          logger.info(
            '✅ Deleted orphaned ephemeral contact: ${contact.displayName}',
          );
        }
      } else {
        logger.fine('Contact has ${messages.length} message(s) - keeping');
      }
    } catch (e) {
      logger.warning('Failed to cleanup ephemeral contact: $e');
    }
  }
}
