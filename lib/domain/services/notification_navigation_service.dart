import 'package:logging/logging.dart';
import '../interfaces/i_notification_navigation_handler.dart';

/// Domain-owned gateway for notification navigation.
///
/// Infrastructure/presentation layers register a concrete handler at startup.
/// Notification handlers call this service to avoid direct dependencies on
/// concrete navigation implementations.
class NotificationNavigationService {
  static final _logger = Logger('NotificationNavigationService');

  static INotificationNavigationHandler? _handler;

  static void setHandler(INotificationNavigationHandler handler) {
    _handler = handler;
    _logger.info('✅ Notification navigation handler registered');
  }

  static void clearHandler() {
    _handler = null;
  }

  static Future<void> navigateToChat({
    required String chatId,
    required String contactName,
    String? contactPublicKey,
  }) async {
    final handler = _handler;
    if (handler == null) {
      _logger.warning('No notification navigation handler registered');
      return;
    }
    await handler.navigateToChat(
      chatId: chatId,
      contactName: contactName,
      contactPublicKey: contactPublicKey,
    );
  }

  static Future<void> navigateToContactRequest({
    required String publicKey,
    required String contactName,
  }) async {
    final handler = _handler;
    if (handler == null) {
      _logger.warning('No notification navigation handler registered');
      return;
    }
    await handler.navigateToContactRequest(
      publicKey: publicKey,
      contactName: contactName,
    );
  }

  static Future<void> navigateToHome() async {
    final handler = _handler;
    if (handler == null) {
      _logger.warning('No notification navigation handler registered');
      return;
    }
    await handler.navigateToHome();
  }
}
