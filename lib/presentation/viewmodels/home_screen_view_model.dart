import 'dart:async';
import 'dart:io' show Platform;

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' as ble;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:logging/logging.dart';
import 'package:state_notifier/state_notifier.dart';

import '../../core/discovery/device_deduplication_manager.dart';
import '../../core/interfaces/i_chats_repository.dart';
import '../../core/models/connection_info.dart';
import '../../core/models/connection_status.dart';
import '../../core/performance/performance_monitor.dart';
import '../../core/services/home_screen_facade.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../domain/services/chat_management_service.dart';
import '../controllers/chat_list_controller.dart';
import '../models/home_screen_state.dart';
import '../providers/ble_providers.dart';
import '../providers/chat_notification_providers.dart';
import '../providers/mesh_networking_provider.dart';
import '../providers/home_screen_providers.dart';

class HomeScreenViewModel extends StateNotifier<HomeScreenState> {
  HomeScreenViewModel(this._ref, this.args) : super(const HomeScreenState()) {
    _chatsRepository = args.chatsRepository;
    _chatManagementService = args.chatManagementService;
    // Keep the provider alive so its listeners stay registered; only dispose what we create.
    _homeScreenFacade =
        args.homeScreenFacade ?? _ref.watch(homeScreenFacadeProvider(args));
    // Provider-owned facades are disposed by the provider; dispose injected ones here.
    _disposeFacadeOnTearDown = args.homeScreenFacade != null;
    _logger = args.logger ?? Logger('HomeScreenViewModel');
    _listController =
        args.chatListController ?? _ref.read(chatListControllerProvider);

    _ref.onDispose(() {
      if (_disposeFacadeOnTearDown) {
        unawaited(_homeScreenFacade.dispose());
      }
    });

    unawaited(_initialize());
  }

  final Ref _ref;
  final HomeScreenProviderArgs args;
  static const int _pageSize = 50;

  late final IChatsRepository _chatsRepository;
  late final ChatManagementService _chatManagementService;
  late final HomeScreenFacade _homeScreenFacade;
  late final Logger _logger;
  final PerformanceMonitor _performanceMonitor = PerformanceMonitor();
  late final ChatListController _listController;
  late final bool _disposeFacadeOnTearDown;

  bool _initialized = false;
  bool _isPaging = false;
  bool _hasMore = true;
  int _offset = 0;
  String _searchQuery = '';

  Future<void> _initialize() async {
    if (_initialized) return;
    _initialized = true;
    await Future.wait([
      _chatManagementService.initialize(),
      _homeScreenFacade.initialize(),
    ]);
    await loadChats(reset: true);
    _setupPeripheralConnectionListener();
    _setupDiscoveryListener();
    _setupUnreadCountStream();
    _setupGlobalMessageListener();
    _setupChatNotificationListeners();
  }

  Future<void> loadChats({bool reset = true}) async {
    _performanceMonitor.startOperation('home_load_chats');
    if (state.isLoading || reset) {
      _updateState(state.copyWith(isLoading: true));
    }

    if (reset) {
      _offset = 0;
      _hasMore = true;
      _isPaging = false;
    }

    final nearbyDevices = await _getNearbyDevices();
    final discoveryDataAsync = _ref.read(discoveryDataProvider);
    final discoveryData = discoveryDataAsync.maybeWhen(
      data: (data) => data,
      orElse: () => <String, DiscoveredEventArgs>{},
    );

    final isSearching = _searchQuery.trim().isNotEmpty;
    final effectiveLimit = isSearching ? null : _pageSize;
    final effectiveOffset = isSearching ? 0 : (reset ? 0 : _offset);

    try {
      final results = await _chatsRepository.getAllChats(
        nearbyDevices: nearbyDevices,
        discoveryData: discoveryData,
        searchQuery: isSearching ? _searchQuery : null,
        limit: effectiveLimit,
        offset: effectiveOffset,
      );
      _performanceMonitor.endOperation('home_load_chats', success: true);

      final merged = _listController.mergeChats(
        existing: state.chats,
        incoming: results,
        reset: reset,
        isSearching: isSearching,
        pageSize: _pageSize,
      );

      _offset = merged.length;
      _hasMore = !isSearching && results.length >= _pageSize;
      _isPaging = false;
      _updateState(
        state.copyWith(
          chats: merged,
          isLoading: false,
          isPaging: false,
          hasMore: _hasMore,
          searchQuery: _searchQuery,
        ),
      );
      _refreshUnreadCount();
    } catch (e) {
      _performanceMonitor.endOperation('home_load_chats', success: false);
      _isPaging = false;
      _updateState(state.copyWith(isLoading: false, isPaging: false));
      rethrow;
    }
  }

  void onSearchChanged(String query) {
    // Single-space sentinel opens the search bar without filtering.
    if (query == ' ') {
      _searchQuery = query;
      _updateState(state.copyWith(searchQuery: _searchQuery));
      return;
    }

    if (query.trim().isEmpty) {
      _searchQuery = '';
      _updateState(state.copyWith(searchQuery: _searchQuery));
      loadChats(reset: true);
      return;
    }

    _searchQuery = query;
    _updateState(state.copyWith(searchQuery: _searchQuery));
    loadChats(reset: true);
  }

  void clearSearch() {
    _searchQuery = '';
    loadChats(reset: true);
  }

  Future<void> updateSingleChatItem() async {
    try {
      final nearbyDevices = await _getNearbyDevices();
      final discoveryDataAsync = _ref.read(discoveryDataProvider);
      final discoveryData = discoveryDataAsync.maybeWhen(
        data: (data) => data,
        orElse: () => <String, DiscoveredEventArgs>{},
      );

      final updatedChats = await _chatsRepository.getAllChats(
        nearbyDevices: nearbyDevices,
        discoveryData: discoveryData,
        searchQuery: _searchQuery.trim().isEmpty ? null : _searchQuery,
        limit: _searchQuery.trim().isEmpty ? _pageSize : null,
        offset: 0,
      );
      if (updatedChats.isEmpty) return;

      final mostRecentChat = updatedChats.first;
      final merged = _listController.applySurgicalUpdate(
        existing: state.chats,
        updated: mostRecentChat,
      );
      _offset = merged.length;
      _updateState(state.copyWith(chats: merged));
      _refreshUnreadCount();
    } catch (e) {
      _logger.warning(
        'Surgical chat update failed, falling back to full reload: $e',
      );
      await loadChats();
    }
  }

  Future<void> openChat(ChatListItem chat) async {
    await _homeScreenFacade.openChat(chat);
    await loadChats();
  }

  Future<bool> showArchiveConfirmation(ChatListItem chat) =>
      _homeScreenFacade.showArchiveConfirmation(chat);

  Future<void> archiveChat(ChatListItem chat) async {
    await _homeScreenFacade.archiveChat(chat);
    await loadChats();
  }

  Future<bool> showDeleteConfirmation(ChatListItem chat) =>
      _homeScreenFacade.showDeleteConfirmation(chat);

  Future<void> deleteChat(ChatListItem chat) async {
    await _homeScreenFacade.deleteChat(chat);
    await loadChats();
  }

  bool isChatPinned(String chatId) =>
      _chatManagementService.isChatPinned(chatId);

  Future<void> markChatAsRead(String chatId) async {
    await _homeScreenFacade.markChatAsRead(chatId);
  }

  Future<void> toggleChatPin(ChatListItem chat) async {
    await _homeScreenFacade.toggleChatPin(chat);
    await loadChats();
  }

  Future<void> handleDeviceSelected(Peripheral device) async {
    _logger.info('Connecting to device: ${device.uuid.toString()}');
    await Future.delayed(const Duration(seconds: 2));
    await loadChats();
  }

  void _setupGlobalMessageListener() {
    _ref.listen<AsyncValue<String>>(receivedMessagesProvider, (previous, next) {
      next.whenData((_) async {
        _logger.info(
          'Global listener: New message received - updating chat list',
        );
        await updateSingleChatItem();
        _refreshUnreadCount();
      });
    });
  }

  Future<List<Peripheral>?> _getNearbyDevices() async {
    final devicesAsync = _ref.read(discoveredDevicesProvider);
    return devicesAsync.maybeWhen(
      data: (devices) => devices,
      orElse: () => null,
    );
  }

  void _setupPeripheralConnectionListener() {
    if (!Platform.isAndroid) return;

    _ref.listen<AsyncValue<CentralConnectionStateChangedEventArgs>>(
      peripheralConnectionChangesProvider,
      (previous, next) {
        next.whenData((event) {
          final bleService = _ref.read(connectionServiceProvider);
          final isConnected =
              event.state == ble.ConnectionState.connected &&
              bleService.isPeripheralMode;

          if (isConnected) {
            _handleIncomingPeripheralConnection(event.central);
          }
        });
      },
    );

    _ref.listen<AsyncValue<ConnectionInfo>>(connectionInfoProvider, (
      previous,
      next,
    ) {
      if (next.hasValue) {
        _refreshUnreadCount();
      }
    });
  }

  void _setupDiscoveryListener() {
    _ref.listen<AsyncValue<Map<String, DiscoveredEventArgs>>>(
      discoveryDataProvider,
      (previous, next) {
        next.whenData((_) {
          if (!state.isLoading) {
            loadChats();
          }
        });
      },
    );
  }

  void _handleIncomingPeripheralConnection(Central central) {
    _logger.fine('Incoming peripheral connection: ${central.uuid}');
    loadChats();
  }

  void _setupUnreadCountStream() {
    if (state.unreadCountStream != null) return;

    // Reuse facade-managed unread count stream to avoid duplicating timers.
    final stream = _homeScreenFacade.unreadCountStream;
    _updateState(state.copyWith(unreadCountStream: stream));
  }

  void _setupChatNotificationListeners() {
    _ref.listen<AsyncValue<ChatUpdateEvent>>(chatUpdatesStreamProvider, (
      previous,
      next,
    ) {
      next.whenData((event) async {
        _logger.fine('Chat update received: $event');
        await updateSingleChatItem();
        _refreshUnreadCount();
      });
    });

    _ref.listen<AsyncValue<MessageUpdateEvent>>(messageUpdatesStreamProvider, (
      previous,
      next,
    ) {
      next.whenData((event) async {
        _logger.fine('Message update received: $event');
        await updateSingleChatItem();
        _refreshUnreadCount();
      });
    });
  }

  void _refreshUnreadCount() {
    _setupUnreadCountStream();
  }

  bool get isPaging => _isPaging;
  bool get hasMore => _hasMore;

  Future<void> loadMoreChats() async {
    if (_isPaging || !_hasMore) return;
    _isPaging = true;
    _updateState(state.copyWith(isPaging: true));
    await loadChats(reset: false);
  }

  Future<void> openContacts() => Future.sync(_homeScreenFacade.openContacts);

  Future<void> openArchives() => Future.sync(_homeScreenFacade.openArchives);

  Future<void> openSettings() => Future.sync(_homeScreenFacade.openSettings);

  Future<void> openProfile() => Future.sync(_homeScreenFacade.openProfile);

  Future<String?> editDisplayName(String currentName) =>
      _homeScreenFacade.editDisplayName(currentName);

  ConnectionStatus determineConnectionStatus({
    required String? contactPublicKey,
    required String contactName,
    required ConnectionInfo? currentConnectionInfo,
    required List<Peripheral> discoveredDevices,
    required Map<String, DiscoveredDevice> discoveryData,
    required DateTime? lastSeenTime,
  }) {
    return _homeScreenFacade.determineConnectionStatus(
      contactPublicKey: contactPublicKey,
      contactName: contactName,
      currentConnectionInfo: currentConnectionInfo,
      discoveredDevices: discoveredDevices,
      discoveryData: discoveryData,
      lastSeenTime: lastSeenTime,
    );
  }

  void _updateState(HomeScreenState newState) {
    state = newState;
  }
}

final homeScreenViewModelProvider = StateNotifierProvider.autoDispose
    .family<HomeScreenViewModel, HomeScreenState, HomeScreenProviderArgs>(
      (ref, args) => HomeScreenViewModel(ref, args),
    );
