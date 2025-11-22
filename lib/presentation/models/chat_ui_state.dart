import 'package:flutter/foundation.dart';
import '../../domain/entities/message.dart';

/// Encapsulates all UI state for ChatScreen
/// Extracted from _ChatScreenState for better testability and separation of concerns
@immutable
class ChatUIState {
  final List<Message> messages;
  final bool isLoading;
  final bool isSearchMode;
  final String searchQuery;
  final bool pairingDialogShown;
  final bool showUnreadSeparator;
  final String initializationStatus;
  final int unreadMessageCount;
  final int newMessagesWhileScrolledUp;
  final bool meshInitializing;
  final bool contactRequestInProgress;

  const ChatUIState({
    this.messages = const [],
    this.isLoading = true,
    this.isSearchMode = false,
    this.searchQuery = '',
    this.pairingDialogShown = false,
    this.showUnreadSeparator = false,
    this.initializationStatus = 'Checking...',
    this.unreadMessageCount = 0,
    this.newMessagesWhileScrolledUp = 0,
    this.meshInitializing = false,
    this.contactRequestInProgress = false,
  });

  /// Create a copy with selected fields updated
  ChatUIState copyWith({
    List<Message>? messages,
    bool? isLoading,
    bool? isSearchMode,
    String? searchQuery,
    bool? pairingDialogShown,
    bool? showUnreadSeparator,
    String? initializationStatus,
    int? unreadMessageCount,
    int? newMessagesWhileScrolledUp,
    bool? meshInitializing,
    bool? contactRequestInProgress,
  }) {
    return ChatUIState(
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      isSearchMode: isSearchMode ?? this.isSearchMode,
      searchQuery: searchQuery ?? this.searchQuery,
      pairingDialogShown: pairingDialogShown ?? this.pairingDialogShown,
      showUnreadSeparator: showUnreadSeparator ?? this.showUnreadSeparator,
      initializationStatus: initializationStatus ?? this.initializationStatus,
      unreadMessageCount: unreadMessageCount ?? this.unreadMessageCount,
      newMessagesWhileScrolledUp:
          newMessagesWhileScrolledUp ?? this.newMessagesWhileScrolledUp,
      meshInitializing: meshInitializing ?? this.meshInitializing,
      contactRequestInProgress:
          contactRequestInProgress ?? this.contactRequestInProgress,
    );
  }

  @override
  String toString() =>
      'ChatUIState(messages=${messages.length}, isLoading=$isLoading, '
      'isSearchMode=$isSearchMode, searchQuery=$searchQuery, '
      'pairingDialogShown=$pairingDialogShown, '
      'showUnreadSeparator=$showUnreadSeparator, '
      'initializationStatus=$initializationStatus, '
      'unreadMessageCount=$unreadMessageCount, '
      'newMessagesWhileScrolledUp=$newMessagesWhileScrolledUp, '
      'meshInitializing=$meshInitializing, '
      'contactRequestInProgress=$contactRequestInProgress)';
}
