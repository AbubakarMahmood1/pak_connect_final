import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../domain/services/chat_management_models.dart';
import '../../domain/services/chat_management_service.dart';

/// Shared logger for chat notification bridging.
final _logger = Logger('ChatNotificationProviders');

/// Provides the shared ChatManagementService singleton.
/// Initialization is triggered lazily to ensure streams are ready when listened to.
final chatManagementServiceProvider = Provider<ChatManagementService>((ref) {
  final service = ChatManagementService.instance;

  // Fire-and-forget initialization; errors are logged but not rethrown to avoid
  // breaking provider resolution in UI layers.
  unawaited(
    service.initialize().catchError((error, stack) {
      _logger.severe(
        'Failed to initialize ChatManagementService',
        error,
        stack,
      );
    }),
  );

  return service;
});

/// StreamProvider bridge for chat-level updates (archive/unarchive/pin/delete).
final chatUpdatesStreamProvider = StreamProvider<ChatUpdateEvent>((ref) {
  final service = ref.watch(chatManagementServiceProvider);
  return service.chatUpdates;
});

/// StreamProvider bridge for message-level updates (star/unstar/etc).
final messageUpdatesStreamProvider = StreamProvider<MessageUpdateEvent>((ref) {
  final service = ref.watch(chatManagementServiceProvider);
  return service.messageUpdates;
});
