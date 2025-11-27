import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/domain/services/chat_notification_service.dart';

/// Provider for ChatNotificationService instance (singleton-like pattern)
final chatNotificationServiceProvider =
    Provider.autoDispose<ChatNotificationService>((ref) {
      final service = ChatNotificationService();
      ref.onDispose(service.dispose);
      return service;
    });

/// Stream provider for chat updates
final chatUpdatesStreamProvider = StreamProvider.autoDispose<dynamic>((
  ref,
) async* {
  final service = ref.watch(chatNotificationServiceProvider);
  yield* service.chatUpdates;
});

/// Stream provider for message updates
final messageUpdatesStreamProvider = StreamProvider.autoDispose<dynamic>((
  ref,
) async* {
  final service = ref.watch(chatNotificationServiceProvider);
  yield* service.messageUpdates;
});
