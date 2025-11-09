// Navigation service for handling navigation from background notifications
// Provides global navigation access without requiring BuildContext

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import '../../presentation/screens/chat_screen.dart';
import '../../presentation/screens/contacts_screen.dart';

/// Global navigation service for background operations
///
/// Allows navigation from anywhere in the app, including notification handlers
/// that don't have access to BuildContext.
///
/// USAGE:
/// ```dart
/// // In main.dart MaterialApp:
/// MaterialApp(
///   navigatorKey: NavigationService.navigatorKey,
///   ...
/// )
///
/// // From anywhere (e.g., notification handler):
/// NavigationService.instance.navigateToChat(chatId: '123', contactName: 'Ali');
/// ```
class NavigationService {
  static final _logger = Logger('NavigationService');

  // Singleton instance
  static final NavigationService _instance = NavigationService._internal();
  static NavigationService get instance => _instance;

  // Global navigator key - MUST be set in MaterialApp
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  NavigationService._internal();

  /// Get the navigator context
  BuildContext? get context => navigatorKey.currentContext;

  /// Get the navigator state
  NavigatorState? get navigator => navigatorKey.currentState;

  /// Navigate to chat screen by chatId
  ///
  /// Used when tapping on a message notification
  Future<void> navigateToChatById({
    required String chatId,
    required String contactName,
    String? contactPublicKey,
  }) async {
    if (navigator == null) {
      _logger.warning('Cannot navigate: navigator not available');
      return;
    }

    try {
      _logger.info('Navigating to chat: $chatId ($contactName)');

      await navigator!.push(
        MaterialPageRoute(
          builder: (context) => ChatScreen.fromChatData(
            chatId: chatId,
            contactName: contactName,
            contactPublicKey: contactPublicKey ?? '',
          ),
        ),
      );
    } catch (e, stackTrace) {
      _logger.severe('Failed to navigate to chat', e, stackTrace);
    }
  }

  /// Navigate to contacts screen (for contact requests)
  ///
  /// Used when tapping on a contact request notification
  Future<void> navigateToContactRequest({
    required String publicKey,
    required String contactName,
  }) async {
    if (navigator == null) {
      _logger.warning('Cannot navigate: navigator not available');
      return;
    }

    try {
      _logger.info('Navigating to contact request: $contactName');

      // Navigate to contacts screen
      // The contact request will be visible there
      await navigator!.push(
        MaterialPageRoute(builder: (context) => const ContactsScreen()),
      );
    } catch (e, stackTrace) {
      _logger.severe('Failed to navigate to contact request', e, stackTrace);
    }
  }

  /// Navigate to home/chats screen
  ///
  /// Used for system notifications or general navigation
  Future<void> navigateToHome() async {
    if (navigator == null) {
      _logger.warning('Cannot navigate: navigator not available');
      return;
    }

    try {
      _logger.info('Navigating to home screen');

      // Pop to root
      navigator!.popUntil((route) => route.isFirst);
    } catch (e, stackTrace) {
      _logger.severe('Failed to navigate to home', e, stackTrace);
    }
  }

  /// Show a dialog/snackbar message
  void showMessage(String message) {
    if (context == null) {
      _logger.warning('Cannot show message: context not available');
      return;
    }

    ScaffoldMessenger.of(
      context!,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
