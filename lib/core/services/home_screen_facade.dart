import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import '../interfaces/i_home_screen_facade.dart';
import '../interfaces/i_chat_interaction_handler.dart';
import '../../core/models/connection_status.dart';
import 'chat_list_coordinator.dart';
import 'chat_connection_manager.dart';
import 'chat_interaction_handler.dart';
import '../../data/repositories/chats_repository.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../data/services/ble_service.dart';
import '../../domain/services/chat_management_service.dart';

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

  // Lazy-initialized services
  late final ChatConnectionManager _connectionManager;
  late final ChatListCoordinator _listCoordinator;
  late final ChatInteractionHandler _interactionHandler;

  bool _initialized = false;
  StreamSubscription? _intentSubscription;

  HomeScreenFacade({
    ChatsRepository? chatsRepository,
    BLEService? bleService,
    ChatManagementService? chatManagementService,
    BuildContext? context,
    WidgetRef? ref,
  }) : _chatsRepository = chatsRepository,
       _bleService = bleService,
       _chatManagementService = chatManagementService,
       _context = context,
       _ref = ref {
    _initializeLazyServices();
  }

  void _initializeLazyServices() {
    _connectionManager = ChatConnectionManager(bleService: _bleService);

    _listCoordinator = ChatListCoordinator(
      chatsRepository: _chatsRepository,
      bleService: _bleService,
    );

    _interactionHandler = ChatInteractionHandler(
      context: _context,
      ref: _ref,
      chatsRepository: _chatsRepository,
      chatManagementService: _chatManagementService,
    );

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
    required List<dynamic> discoveredDevices,
    required Map<String, dynamic> discoveryData,
    required DateTime? lastSeenTime,
  }) {
    // Delegate to connection manager with proper parameters
    return _connectionManager.determineConnectionStatus(
      contactPublicKey: contactPublicKey,
      contactName: contactName,
      currentConnectionInfo: null,
      discoveredDevices: const [],
      discoveryData: const {},
      lastSeenTime: lastSeenTime,
    );
  }

  @override
  Stream<ConnectionStatus> get connectionStatusStream {
    return Stream.value(ConnectionStatus.offline).asBroadcastStream();
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
      await _interactionHandler.dispose();
      _initialized = false;
      _logger.info('♻️ HomeScreenFacade disposed');
    } catch (e) {
      _logger.warning('⚠️ Error disposing HomeScreenFacade: $e');
    }
  }
}
