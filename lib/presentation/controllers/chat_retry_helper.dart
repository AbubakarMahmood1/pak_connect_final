import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:get_it/get_it.dart';

import '../../domain/services/message_retry_coordinator.dart';
import '../../domain/utils/string_extensions.dart';
import '../../domain/entities/message.dart';
import '../../domain/interfaces/i_message_repository.dart';
import '../../domain/interfaces/i_shared_message_queue_provider.dart';
import '../../domain/values/id_types.dart';
import '../../domain/messaging/offline_message_queue_contract.dart';
import '../models/chat_screen_config.dart';
import '../../presentation/providers/ble_providers.dart';
import '../../presentation/providers/mesh_networking_provider.dart';

class ChatRetryHelper {
  ChatRetryHelper({
    required this.ref,
    required this.config,
    required this.chatId,
    required this.contactPublicKey,
    required this.displayContactName,
    required this.messageRepository,
    required this.repositoryRetryHandler,
    required this.showSuccess,
    required this.showError,
    required this.showInfo,
    required this.scrollToBottom,
    required this.getMessages,
    this.offlineQueueResolver,
    Logger? logger,
    MessageRetryCoordinator? initialCoordinator,
    Duration? fallbackRetryDelay,
  }) : _logger = logger ?? Logger('ChatRetryHelper'),
       _retryCoordinator = initialCoordinator,
       _fallbackRetryDelay =
           fallbackRetryDelay ?? const Duration(milliseconds: 500);

  final WidgetRef ref;
  final ChatScreenConfig config;
  final String Function() chatId;
  final String? Function() contactPublicKey;
  final String Function() displayContactName;
  final IMessageRepository messageRepository;
  final Future<void> Function(Message) repositoryRetryHandler;
  final void Function(String) showSuccess;
  final void Function(String) showError;
  final void Function(String) showInfo;
  final void Function() scrollToBottom;
  final List<Message> Function() getMessages;
  final OfflineMessageQueueContract? Function()? offlineQueueResolver;
  final Logger _logger;
  final Duration _fallbackRetryDelay;

  MessageRetryCoordinator? _retryCoordinator;

  void ensureRetryCoordinator() {
    if (_retryCoordinator != null) return;
    try {
      final offlineQueue = offlineQueueResolver != null
          ? offlineQueueResolver!()
          : null;
      OfflineMessageQueueContract? queue = offlineQueue;
      if (queue == null &&
          GetIt.instance.isRegistered<ISharedMessageQueueProvider>()) {
        final sharedProvider = GetIt.instance<ISharedMessageQueueProvider>();
        if (sharedProvider.isInitialized) {
          queue = sharedProvider.messageQueue;
        }
      }
      if (queue == null) {
        _logger.fine(
          'Offline queue unavailable; deferring MessageRetryCoordinator setup',
        );
        return;
      }

      final meshService = ref.read(meshNetworkingServiceProvider);

      _retryCoordinator = MessageRetryCoordinator(
        offlineQueue: queue,
        meshService: meshService,
      );
    } catch (e) {
      _logger.warning('Failed to initialize MessageRetryCoordinator: $e');
    }
  }

  Future<void> autoRetryFailedMessages() async {
    if (_retryCoordinator == null) return;
    try {
      final connectionInfo = ref.read(connectionInfoProvider).value;
      final isConnected = connectionInfo?.isConnected ?? false;
      final allowPartialConnection = isConnected;

      if (!isConnected) {
        showSuccess(
          'Attempting retry - messages will be queued if connection fails...',
        );
      } else {
        showSuccess('Connection available - retrying failed messages...');
      }

      final chatIdValue = ChatId(chatId());
      final retryStatus = await _retryCoordinator!.getFailedMessageStatus(
        chatIdValue,
      );

      if (retryStatus.hasError) {
        showError('Failed to check message status - ${retryStatus.error}');
        return;
      }

      if (!retryStatus.hasFailedMessages) {
        return;
      }

      showSuccess(
        'Retrying ${retryStatus.totalFailed} failed message${retryStatus.totalFailed > 1 ? 's' : ''}...',
      );

      final retryResult = await _retryCoordinator!.retryAllFailedMessages(
        chatId: chatIdValue,
        allowPartialConnection: allowPartialConnection,
        onRepositoryMessageRetry: (message) => repositoryRetryHandler(message),
        onQueueMessageRetry: (_) async {},
      );

      scrollToBottom();

      final stillFailed = getMessages()
          .where((m) => m.isFromMe && m.status == MessageStatus.failed)
          .length;

      if (retryResult.success && retryResult.totalSucceeded > 0) {
        showSuccess('✅ ${retryResult.message}');
      } else if (stillFailed > 0) {
        showError('⚠️ ${retryResult.message}');
      } else {
        showSuccess('✅ All messages processed - ${retryResult.message}');
      }
    } catch (e) {
      _logger.severe('Retry coordination error: $e');
      showError('Retry coordination error - falling back to individual retry');
      await fallbackRetryFailedMessages();
    }
  }

  Future<void> repositoryRetryMessage(Message message) async {
    try {
      final retryMessage = message.copyWith(status: MessageStatus.sending);
      await messageRepository.updateMessage(retryMessage);
      await repositoryRetryHandler(retryMessage);
    } catch (e) {
      _logger.warning(
        'Repository retry failed for ${message.id.value.shortId()}: $e',
      );
      rethrow;
    }
  }

  Future<void> fallbackRetryFailedMessages() async {
    final failedMessages = getMessages()
        .where((m) => m.isFromMe && m.status == MessageStatus.failed)
        .toList();

    if (failedMessages.isEmpty) {
      return;
    }

    int successCount = 0;
    for (final message in failedMessages) {
      try {
        // Use repository-aware retry to flip status before sending.
        await repositoryRetryMessage(message);
        successCount++;
      } catch (_) {}
      await _delayForFallbackRetry();
    }

    if (successCount > 0) {
      showSuccess(
        '✅ Fallback retry delivered $successCount message${successCount > 1 ? 's' : ''}',
      );
    } else {
      showError(
        '⚠️ Fallback retry failed - messages will retry automatically when connection improves',
      );
    }
  }

  void dispose() {
    _retryCoordinator = null;
  }

  Future<void> _delayForFallbackRetry() {
    if (_fallbackRetryDelay == Duration.zero) {
      return Future.value();
    }
    return Future.delayed(_fallbackRetryDelay);
  }
}
