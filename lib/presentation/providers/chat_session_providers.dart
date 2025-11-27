import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/interfaces/i_connection_service.dart';
import '../../core/interfaces/i_mesh_networking_service.dart';
import '../../core/messaging/message_router.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/models/connection_info.dart';
import '../../core/security/message_security.dart';
import '../../core/services/message_retry_coordinator.dart';
import '../../data/repositories/chats_repository.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/message_repository.dart';
import '../../domain/models/mesh_network_models.dart';
import '../../domain/services/notification_service.dart';
import '../controllers/chat_pairing_dialog_controller.dart';
import '../controllers/chat_scrolling_controller.dart' as chat_controller;
import '../controllers/chat_search_controller.dart';
import '../controllers/chat_session_lifecycle.dart';
import '../controllers/chat_screen_controller.dart';
import '../models/chat_screen_config.dart';
import '../models/chat_ui_state.dart';
import '../notifiers/chat_session_state_notifier.dart';
import '../notifiers/chat_session_state_provider.dart';
import '../providers/chat_messaging_view_model.dart';
import '../viewmodels/chat_session_view_model.dart';
import 'ble_providers.dart';

/// Aggregated handle for provider-backed session consumption.
class ChatSessionHandle {
  const ChatSessionHandle({
    required this.state,
    required this.actions,
    required this.viewModel,
    required this.lifecycle,
  });

  final ChatUIState state;
  final ChatSessionActions actions;
  final ChatSessionViewModel viewModel;
  final ChatSessionLifecycle lifecycle;
}

final chatSessionOwnedStateNotifierProvider = NotifierProvider.autoDispose
    .family<
      ChatSessionOwnedStateNotifier,
      ChatUIState,
      ChatScreenControllerArgs
    >(ChatSessionOwnedStateNotifier.new);

final chatSessionStateStoreProvider = StateNotifierProvider.autoDispose
    .family<ChatSessionStateStore, ChatUIState, ChatScreenControllerArgs>(
      (ref, args) => ChatSessionStateStore(),
    );

/// Preferred state provider for migrated consumers.
// Preferred state provider exported via chat_session_state_provider.dart.

/// Simple action facade backed by ChatScreenController (for migration).
class ChatSessionActions {
  const ChatSessionActions({
    required this.sendMessage,
    required this.deleteMessage,
    required this.retryFailedMessages,
    required this.manualReconnection,
    required this.retryFailedMessagesInline,
    required this.requestPairing,
    required this.handleAsymmetricContact,
    required this.handleConnectionChange,
    required this.handleMeshInitializationStatusChange,
    required this.scrollToBottom,
    required this.toggleSearchMode,
  });

  final Future<void> Function(String content) sendMessage;
  final Future<void> Function(String messageId, bool deleteForEveryone)
  deleteMessage;
  final Future<void> Function() retryFailedMessages;
  final Future<void> Function() manualReconnection;
  final Future<void> Function() retryFailedMessagesInline;
  final Future<void> Function() requestPairing;
  final Future<void> Function(String publicKey, String displayName)
  handleAsymmetricContact;
  final void Function(ConnectionInfo?, ConnectionInfo?) handleConnectionChange;
  final void Function(
    AsyncValue<MeshNetworkStatus>?,
    AsyncValue<MeshNetworkStatus>,
  )
  handleMeshInitializationStatusChange;
  final void Function() scrollToBottom;
  final void Function() toggleSearchMode;
}

/// Arguments for constructing a ChatSessionViewModel via provider family.
class ChatSessionProviderArgs {
  const ChatSessionProviderArgs({
    required this.config,
    required this.messageRepository,
    required this.contactRepository,
    required this.chatsRepository,
    required this.messagingViewModel,
    required this.scrollingController,
    required this.searchController,
    required this.pairingDialogController,
    this.retryCoordinator,
  });

  final ChatScreenConfig config;
  final MessageRepository messageRepository;
  final ContactRepository contactRepository;
  final ChatsRepository chatsRepository;
  final ChatMessagingViewModel messagingViewModel;
  final chat_controller.ChatScrollingController scrollingController;
  final ChatSearchController searchController;
  final ChatPairingDialogController pairingDialogController;
  final MessageRetryCoordinator? retryCoordinator;
}

/// Arguments for constructing a ChatSessionLifecycle via provider family.
class ChatSessionLifecycleArgs {
  const ChatSessionLifecycleArgs({
    required this.viewModel,
    required this.connectionService,
    required this.meshService,
    this.messageRouter,
    required this.messageSecurity,
    required this.messageRepository,
    this.retryCoordinator,
    this.offlineQueue,
    this.notificationService,
  });

  final ChatSessionViewModel viewModel;
  final IConnectionService connectionService;
  final IMeshNetworkingService meshService;
  final MessageRouter? messageRouter;
  final MessageSecurity messageSecurity;
  final MessageRepository messageRepository;
  final MessageRetryCoordinator? retryCoordinator;
  final OfflineMessageQueue? offlineQueue;
  final NotificationService? notificationService;
}

/// Provider family for ChatSessionViewModel scaffolding.
final chatSessionViewModelProvider =
    Provider.family<ChatSessionViewModel, ChatSessionProviderArgs>(
      (ref, args) => ChatSessionViewModel(
        config: args.config,
        messageRepository: args.messageRepository,
        contactRepository: args.contactRepository,
        chatsRepository: args.chatsRepository,
        messagingViewModel: args.messagingViewModel,
        scrollingController: args.scrollingController,
        searchController: args.searchController,
        pairingDialogController: args.pairingDialogController,
        retryCoordinator: args.retryCoordinator,
      ),
    );

/// Provider family for ChatSessionLifecycle scaffolding.
final chatSessionLifecycleProvider =
    Provider.family<ChatSessionLifecycle, ChatSessionLifecycleArgs>(
      (ref, args) => ChatSessionLifecycle(
        viewModel: args.viewModel,
        connectionService: args.connectionService,
        meshService: args.meshService,
        messageRouter: args.messageRouter,
        messageSecurity: args.messageSecurity,
        messageRepository: args.messageRepository,
        retryCoordinator: args.retryCoordinator,
        offlineQueue: args.offlineQueue,
        notificationService: args.notificationService,
      ),
    );

/// Helper to resolve the current connection service via existing providers.
IConnectionService resolveConnectionService(WidgetRef ref) =>
    ref.read(connectionServiceProvider);

/// Compatibility providers to access the new Session ViewModel/Lifecycle via the
/// existing ChatScreenController while widgets are migrated.
final chatSessionViewModelFromControllerProvider =
    Provider.family<ChatSessionViewModel, ChatScreenControllerArgs>((
      ref,
      args,
    ) {
      final controller = ref.watch(chatScreenControllerProvider(args));
      return controller.sessionViewModel;
    });

final chatSessionLifecycleFromControllerProvider =
    Provider.family<ChatSessionLifecycle, ChatScreenControllerArgs>((
      ref,
      args,
    ) {
      final controller = ref.watch(chatScreenControllerProvider(args));
      return controller.sessionLifecycle;
    });

/// Compatibility provider to read ChatUIState via the existing controller.
// Legacy mirror provider kept for backward compatibility; prefers notifier when available.
final chatSessionStateFromControllerProvider = chatSessionStateMirrorProvider;

final chatSessionStateNotifierProvider = NotifierProvider.autoDispose
    .family<ChatSessionStateNotifier, ChatUIState, ChatScreenControllerArgs>(
      ChatSessionStateNotifier.new,
    );

/// Compatibility provider to access controller-backed actions for migration.
final chatSessionActionsFromControllerProvider =
    Provider.family<ChatSessionActions, ChatScreenControllerArgs>((ref, args) {
      final controller = ref.watch(chatScreenControllerProvider(args));
      final viewModel = controller.sessionViewModel;
      return ChatSessionActions(
        sendMessage: viewModel.sendMessage,
        deleteMessage: viewModel.deleteMessage,
        retryFailedMessages: viewModel.retryFailedMessages,
        manualReconnection: controller.manualReconnection,
        retryFailedMessagesInline: viewModel.retryFailedMessages,
        requestPairing: controller.userRequestedPairing,
        handleAsymmetricContact: controller.handleAsymmetricContact,
        handleConnectionChange: controller.handleConnectionChange,
        handleMeshInitializationStatusChange:
            controller.handleMeshInitializationStatusChange,
        scrollToBottom: viewModel.scrollToBottom,
        toggleSearchMode: viewModel.toggleSearchMode,
      );
    });

/// Provider that aggregates session state/actions/view model/lifecycle for opt-in.
final chatSessionHandleProvider =
    Provider.family<ChatSessionHandle, ChatScreenControllerArgs>((ref, args) {
      final state = ref.watch(chatSessionOwnedStateNotifierProvider(args));
      final actions = ref.watch(chatSessionActionsFromControllerProvider(args));
      final viewModel = ref.watch(
        chatSessionViewModelFromControllerProvider(args),
      );
      final lifecycle = ref.watch(
        chatSessionLifecycleFromControllerProvider(args),
      );
      return ChatSessionHandle(
        state: state,
        actions: actions,
        viewModel: viewModel,
        lifecycle: lifecycle,
      );
    });
