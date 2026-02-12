import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/services/pinning_service.dart';
import 'package:pak_connect/domain/services/chat_management_models.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/presentation/providers/di_providers.dart';

final _logger = Logger('PinningServiceProvider');

/// Provider for PinningService instance
final pinningServiceProvider = Provider.autoDispose<PinningService>((ref) {
  final service = PinningService(
    chatsRepository: resolveFromAppServicesOrServiceLocator<IChatsRepository>(
      fromServices: (services) => services.chatsRepository,
      dependencyName: 'IChatsRepository',
    ),
    messageRepository:
        resolveFromAppServicesOrServiceLocator<IMessageRepository>(
          fromServices: (services) => services.messageRepository,
          dependencyName: 'IMessageRepository',
        ),
  );

  unawaited(
    service.initialize().catchError((error, stack) {
      _logger.severe('Failed to initialize PinningService', error, stack);
    }),
  );

  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

/// Stream provider for message update events
final messageUpdatesProvider = StreamProvider.autoDispose<MessageUpdateEvent>((
  ref,
) async* {
  final service = ref.watch(pinningServiceProvider);
  yield* service.messageUpdates;
});
