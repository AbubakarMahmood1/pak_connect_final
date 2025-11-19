import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import '../interfaces/i_home_screen_facade.dart';
import '../interfaces/i_chat_interaction_handler.dart';
import '../../core/models/connection_status.dart';
import '../../core/models/connection_info.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import 'chat_list_coordinator.dart';
import 'chat_connection_manager.dart';
import '../../data/repositories/chats_repository.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../data/services/ble_service.dart';
import '../../domain/services/chat_management_service.dart';

typedef ChatInteractionHandlerBuilder =
    IChatInteractionHandler Function({
      BuildContext? context,
      WidgetRef? ref,
      ChatsRepository? chatsRepository,
      ChatManagementService? chatManagementService,
    });

/// Facade for HomeScreen state and operations
///
/// Orchestrates three core services:
/// - ChatConnectionManager: BLE connection state and online status detection
/// - ChatListCoordinator: Chat loading, refreshing, and real-time updates
/// - ChatInteractionHandler: All user interactions and navigation
///
/// Provides:
/// - Lazy initialization of sub-services (only created when first accessed)
/// - Clean delegation API (100% backward compatible)
/// - Event stream for interaction-triggered refreshes
/// - Unified initialization and disposal
///
/// Pattern:
/// - HomeScreen calls facade methods instead of local methods
/// - Facade coordinates which service owns the operation
/// - Interaction events trigger coordinator refreshes
/// - All dependencies injected via constructor (testable)
class HomeScreenFacade implements IHomeScreenFacade {
  final _logger = Logger('HomeScreenFacade');

  final ChatsRepository? _chatsRepository;
  final BLEService? _bleService;
  final ChatManagementService? _chatManagementService;
  final BuildContext? _context;
  final WidgetRef? _ref;
  final ChatInteractionHandlerBuilder? _interactionHandlerBuilder;

  // Lazy-initialized services
  late final ChatConnectionManager _connectionManager;
  late final ChatListCoordinator _listCoordinator;
  late final IChatInteractionHandler _interactionHandler;

  bool _initialized = false;
  StreamSubscription? _intentSubscription;

  HomeScreenFacade({
    ChatsRepository? chatsRepository,
    BLEService? bleService,
    ChatManagementService? chatManagementService,
    BuildContext? context,
    WidgetRef? ref,
    ChatInteractionHandlerBuilder? interactionHandlerBuilder,
  }) : _chatsRepository = chatsRepository,
       _bleService = bleService,
       _chatManagementService = chatManagementService,
       _context = context,
       _ref = ref,
       _interactionHandlerBuilder = interactionHandlerBuilder {
    _initializeLazyServices();
  }

  void _initializeLazyServices() {
    _connectionManager = ChatConnectionManager(bleService: _bleService);

    _listCoordinator = ChatListCoordinator(
      chatsRepository: _chatsRepository,
      bleService: _bleService,
      connectionStatusStream: _connectionManager.connectionStatusStream,
    );

    _interactionHandler = _interactionHandlerBuilder != null
        ? _interactionHandlerBuilder!(
            context: _context,
            ref: _ref,
            chatsRepository: _chatsRepository,
            chatManagementService: _chatManagementService,
          )
        : _NullChatInteractionHandler();

    // Listen to interaction intents and refresh chat list when needed
    _intentSubscription = _interactionHandler.interactionIntentStream.listen((
      intent,
    ) async {
      if (intent is ChatOpenedIntent ||
          intent is ChatArchivedIntent ||
          intent is ChatDeletedIntent ||
          intent is ChatPinToggleIntent) {
        _logger.fine('🔄 Interaction triggered refresh');
        await _listCoordinator.loadChats();
      }
    });
  }

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      await _interactionHandler.initialize();
      await _listCoordinator.initialize();
      await _connectionManager.initialize();
      _setupPeriodicRefresh();
      _setupGlobalMessageListener();
      _initialized = true;
      _logger.info('✅ HomeScreenFacade initialized');
    } catch (e) {
      _logger.severe('❌ Error initializing HomeScreenFacade: $e');
      rethrow;
    }
  }

  // ============================================================
  // ChatListCoordinator delegations (chat loading and refresh)
  // ============================================================

  @override
  Future<List<ChatListItem>> loadChats({String? searchQuery}) =>
      _listCoordinator.loadChats(searchQuery: searchQuery);

  /// Internal: Setup periodic refresh (called during initialize)
  void _setupPeriodicRefresh() => _listCoordinator.setupPeriodicRefresh();

  /// Internal: Setup global message listener (called during initialize)
  void _setupGlobalMessageListener() =>
      _listCoordinator.setupGlobalMessageListener();

  /// Internal: Update single chat item (called when message arrives)
  Future<void> _updateSingleChatItem() =>
      _listCoordinator.updateSingleChatItem();

  @override
  Stream<int> get unreadCountStream => _listCoordinator.unreadCountStream;

  @override
  List<ChatListItem> get chats => _listCoordinator.currentChats;

  @override
  bool get isLoading => _listCoordinator.isLoading;

  @override
  void refreshUnreadCount() {
    _listCoordinator.refreshUnreadCount();
  }

  // ============================================================
  // ChatConnectionManager delegations (BLE connection state)
  // ============================================================

  @override
  ConnectionStatus determineConnectionStatus({
    required String? contactPublicKey,
    required String contactName,
    required ConnectionInfo? currentConnectionInfo,
    required List<Peripheral> discoveredDevices,
    required Map<String, DiscoveredDevice> discoveryData,
    required DateTime? lastSeenTime,
  }) {
    // Diagnostic logging: log when we have no discovery signals for this contact
    if (discoveredDevices.isEmpty &&
        discoveryData.isEmpty &&
        lastSeenTime == null) {
      _logger.fine(
        '⚠️ No discovery signals for $contactName (no nearby devices, no lastSeen)',
      );
    }

    // Delegate to connection manager with actual discovery parameters and connection info
    return _connectionManager.determineConnectionStatus(
      contactPublicKey: contactPublicKey,
      contactName: contactName,
      currentConnectionInfo: currentConnectionInfo,
      discoveredDevices: discoveredDevices,
      discoveryData: discoveryData,
      lastSeenTime: lastSeenTime,
    );
  }

  @override
  Stream<ConnectionStatus> get connectionStatusStream {
    // 🔄 Proxy connection manager's stream so UI can react to BLE discovery changes
    return _connectionManager.connectionStatusStream;
  }

  // ============================================================
  // ChatInteractionHandler delegations (user interactions)
  // ============================================================

  @override
  Future<void> openChat(ChatListItem chat) =>
      _interactionHandler.openChat(chat);

  @override
  void toggleSearch() => _interactionHandler.toggleSearch();

  @override
  void showSearch() => _interactionHandler.showSearch();

  @override
  Future<void> clearSearch() => _listCoordinator.clearSearch().then((_) {
    _interactionHandler.clearSearch();
  });

  @override
  void openSettings() => _interactionHandler.openSettings();

  @override
  void openProfile() => _interactionHandler.openProfile();

  @override
  Future<String?> editDisplayName(String currentName) =>
      _interactionHandler.editDisplayName(currentName);

  @override
  void handleMenuAction(String action) =>
      _interactionHandler.handleMenuAction(action);

  @override
  void openContacts() => _interactionHandler.openContacts();

  @override
  void openArchives() => _interactionHandler.openArchives();

  @override
  Future<bool> showArchiveConfirmation(ChatListItem chat) =>
      _interactionHandler.showArchiveConfirmation(chat);

  @override
  Future<void> archiveChat(ChatListItem chat) =>
      _interactionHandler.archiveChat(chat);

  @override
  Future<bool> showDeleteConfirmation(ChatListItem chat) =>
      _interactionHandler.showDeleteConfirmation(chat);

  @override
  Future<void> deleteChat(ChatListItem chat) =>
      _interactionHandler.deleteChat(chat);

  @override
  void showChatContextMenu(ChatListItem chat) =>
      _interactionHandler.showChatContextMenu(chat);

  @override
  Future<void> toggleChatPin(ChatListItem chat) =>
      _interactionHandler.toggleChatPin(chat);

  @override
  Future<void> markChatAsRead(String chatId) =>
      _interactionHandler.markChatAsRead(chatId);

  @override
  Future<void> dispose() async {
    try {
      await _intentSubscription?.cancel();
      await _listCoordinator.dispose();
      await _connectionManager.dispose();
      await _interactionHandler.dispose();
      _initialized = false;
      _logger.info('♻️ HomeScreenFacade disposed');
    } catch (e) {
      _logger.warning('⚠️ Error disposing HomeScreenFacade: $e');
    }
  }
}

class _NullChatInteractionHandler implements IChatInteractionHandler {
  final StreamController<ChatInteractionIntent> _controller =
      StreamController.broadcast();

  @override
  Future<void> initialize() async {}

  @override
  Stream<ChatInteractionIntent> get interactionIntentStream =>
      _controller.stream;

  @override
  Future<void> dispose() async {
    await _controller.close();
  }

  @override
  Future<void> openChat(ChatListItem chat) async {}

  @override
  void toggleSearch() {}

  @override
  void showSearch() {}

  @override
  void clearSearch() {}

  @override
  void openSettings() {}

  @override
  void openProfile() {}

  @override
  Future<String?> editDisplayName(String currentName) async => null;

  @override
  void handleMenuAction(String action) {}

  @override
  void openContacts() {}

  @override
  void openArchives() {}

  @override
  Future<bool> showArchiveConfirmation(ChatListItem chat) async => false;

  @override
  Future<void> archiveChat(ChatListItem chat) async {}

  @override
  Future<bool> showDeleteConfirmation(ChatListItem chat) async => false;

  @override
  Future<void> deleteChat(ChatListItem chat) async {}

  @override
  void showChatContextMenu(ChatListItem chat) {}

  @override
  Future<void> toggleChatPin(ChatListItem chat) async {}

  @override
  Future<void> markChatAsRead(String chatId) async {}
}
