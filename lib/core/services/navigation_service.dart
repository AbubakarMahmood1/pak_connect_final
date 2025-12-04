// Navigation service for handling navigation from background notifications
// Provides global navigation access without requiring BuildContext

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import '../../domain/values/id_types.dart';

/// Type definitions for screen builders
/// These allow the presentation layer to register screen implementations
/// without the core layer importing from presentation
typedef ChatScreenBuilder =
    Widget Function({
      required ChatId chatId,
      required String contactName,
      required String contactPublicKey,
    });

typedef ContactsScreenBuilder = Widget Function();

/// Global navigation service for background operations
///
/// Allows navigation from anywhere in the app, including notification handlers
/// that don't have access to BuildContext.
///
/// Uses callback-based registration to avoid Core → Presentation layer violations.
///
/// USAGE:
/// ```dart
/// // In presentation layer (e.g., main.dart):
/// NavigationService.setChatScreenBuilder(
///   ({required chatId, required contactName, required contactPublicKey}) =>
///     ChatScreen.fromChatData(chatId: chatId, contactName: contactName, contactPublicKey: contactPublicKey),
/// );
/// NavigationService.setContactsScreenBuilder(() => const ContactsScreen());
///
/// // In MaterialApp:
/// MaterialApp(
///   navigatorKey: NavigationService.navigatorKey,
///   ...
/// )
///
/// // From anywhere (e.g., notification handler):
/// NavigationService.instance.navigateToChatById(chatId: '123', contactName: 'Ali');
/// ```
class NavigationService {
  static final _logger = Logger('NavigationService');

  // Singleton instance
  static final NavigationService _instance = NavigationService._internal();
  static NavigationService get instance => _instance;

  // Global navigator key - MUST be set in MaterialApp
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  // Screen builders - registered by presentation layer
  static ChatScreenBuilder? _chatScreenBuilder;
  static ContactsScreenBuilder? _contactsScreenBuilder;

  NavigationService._internal();

  /// Register the ChatScreen builder
  /// Called from presentation layer during initialization
  static void setChatScreenBuilder(ChatScreenBuilder builder) {
    _chatScreenBuilder = builder;
    _logger.info('✅ ChatScreen builder registered');
  }

  /// Register the ContactsScreen builder
  /// Called from presentation layer during initialization
  static void setContactsScreenBuilder(ContactsScreenBuilder builder) {
    _contactsScreenBuilder = builder;
    _logger.info('✅ ContactsScreen builder registered');
  }

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

    if (_chatScreenBuilder == null) {
      _logger.severe(
        'Cannot navigate to chat: ChatScreen builder not registered. '
        'Call NavigationService.setChatScreenBuilder() during app initialization.',
      );
      return;
    }

    try {
      final typedChatId = ChatId(chatId);
      _logger.info(
        '📱 Navigating to chat: ${typedChatId.value} ($contactName)',
      );

      await navigator!.push(
        MaterialPageRoute(
          builder: (context) => _chatScreenBuilder!(
            chatId: typedChatId,
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

    if (_contactsScreenBuilder == null) {
      _logger.severe(
        'Cannot navigate to contacts: ContactsScreen builder not registered. '
        'Call NavigationService.setContactsScreenBuilder() during app initialization.',
      );
      return;
    }

    try {
      _logger.info('📋 Navigating to contact request: $contactName');

      // Navigate to contacts screen
      // The contact request will be visible there
      await navigator!.push(
        MaterialPageRoute(builder: (context) => _contactsScreenBuilder!()),
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
      _logger.info('🏠 Navigating to home screen');

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
