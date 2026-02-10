import 'dart:async';
import 'dart:io' show Platform;

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' as ble;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:logging/logging.dart';

import '../../core/discovery/device_deduplication_manager.dart';
import '../../core/interfaces/i_chats_repository.dart';
import '../../core/models/connection_info.dart';
import '../../core/models/connection_status.dart';
import '../../core/services/home_screen_facade.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../domain/services/chat_management_service.dart';
import '../../domain/values/id_types.dart';
import '../providers/ble_providers.dart';
import '../../core/performance/performance_monitor.dart';

class HomeScreenControllerArgs {
  const HomeScreenControllerArgs({
    required this.context,
    required this.ref,
    required this.chatsRepository,
    required this.chatManagementService,
    this.logger,
    this.homeScreenFacade,
  });

  final BuildContext context;
  final WidgetRef ref;
  final IChatsRepository chatsRepository;
  final ChatManagementService chatManagementService;
  final Logger? logger;
  final HomeScreenFacade? homeScreenFacade;
}

class HomeScreenController extends ChangeNotifier {
  HomeScreenController(HomeScreenControllerArgs args)
    : ref = args.ref,
      context = args.context,
      _logger = args.logger ?? Logger('HomeScreenController'),
      _chatsRepository = args.chatsRepository,
      _chatManagementService = args.chatManagementService,
      _homeScreenFacade =
          args.homeScreenFacade ??
          HomeScreenFacade(
            chatsRepository: args.chatsRepository,
            bleService: args.ref.read(connectionServiceProvider),
            chatManagementService: args.chatManagementService,
            context: args.context,
            ref: args.ref,
            enableListCoordinatorInitialization: false,
          );

  final WidgetRef ref;
  final BuildContext context;
  final Logger _logger;
  final IChatsRepository _chatsRepository;
  final ChatManagementService _chatManagementService;
  final HomeScreenFacade _homeScreenFacade;
  final PerformanceMonitor _performanceMonitor = PerformanceMonitor();

  bool _isDisposed = false;
  bool _isPaging = false;
  bool _hasMore = true;
  int _offset = 0;
  static const int _pageSize = 50;
  List<ChatListItem> chats = [];
  bool isLoading = true;
  String searchQuery = '';
  Stream<int>? unreadCountStream;

  StreamSubscription? _peripheralConnectionSubscription;
  StreamSubscription? _connectionInfoSubscription;
  StreamSubscription? _discoveryDataSubscription;
  StreamSubscription? _globalMessageSubscription;

  Future<void> initialize() async {
    if (_isDisposed) return;
    await Future.wait([
      _chatManagementService.initialize(),
      _homeScreenFacade.initialize(),
    ]);
    if (_isDisposed) return;
    await loadChats(reset: true);
    _setupPeripheralConnectionListener();
    _setupDiscoveryListener();
    _setupUnreadCountStream();
    _setupGlobalMessageListener();
  }

  Future<void> loadChats({bool reset = true}) async {
    if (_isDisposed) return;
    _performanceMonitor.startOperation('home_load_chats');
    if (isLoading || reset) {
      _safeNotifyListeners();
    }

    if (reset) {
      _offset = 0;
      _hasMore = true;
      _isPaging = false;
    }

    final nearbyDevices = await _getNearbyDevices();
    if (_isDisposed) return;
    final discoveryDataAsync = ref.read(discoveryDataProvider);
    final discoveryData = discoveryDataAsync.maybeWhen(
      data: (data) => data,
      orElse: () => <String, DiscoveredEventArgs>{},
    );

    final isSearching = searchQuery.trim().isNotEmpty;
    final effectiveLimit = isSearching ? null : _pageSize;
    final effectiveOffset = isSearching ? 0 : (reset ? 0 : _offset);

    List<ChatListItem> results = [];
    try {
      results = await _chatsRepository.getAllChats(
        nearbyDevices: nearbyDevices,
        discoveryData: discoveryData,
        searchQuery: isSearching ? searchQuery : null,
        limit: effectiveLimit,
        offset: effectiveOffset,
      );
      _performanceMonitor.endOperation('home_load_chats', success: true);
    } catch (e) {
      _performanceMonitor.endOperation('home_load_chats', success: false);
      if (!_isDisposed) {
        isLoading = false;
        _isPaging = false;
        _safeNotifyListeners();
      }
      rethrow;
    }

    if (_isDisposed) return;
    if (reset) {
      chats = results;
      _offset = results.length;
    } else {
      chats = [...chats, ...results];
      _offset = chats.length;
    }
    _hasMore = !isSearching && results.length >= _pageSize;
    isLoading = false;
    _isPaging = false;
    _safeNotifyListeners();
    _refreshUnreadCount();
  }

  void onSearchChanged(String query) {
    if (_isDisposed) return;
    // Single-space sentinel opens the search bar without filtering.
    if (query == ' ') {
      searchQuery = query;
      _safeNotifyListeners();
      return;
    }

    // Empty/whitespace clears search and reloads full list immediately.
    if (query.trim().isEmpty) {
      searchQuery = '';
      _safeNotifyListeners();
      loadChats(reset: true);
      return;
    }

    searchQuery = query;
    _safeNotifyListeners();
    loadChats(reset: true);
  }

  void clearSearch() {
    if (_isDisposed) return;
    searchQuery = '';
    loadChats(reset: true);
  }

  Future<void> updateSingleChatItem() async {
    if (_isDisposed) return;
    try {
      final nearbyDevices = await _getNearbyDevices();
      if (_isDisposed) return;
      final discoveryDataAsync = ref.read(discoveryDataProvider);
      final discoveryData = discoveryDataAsync.maybeWhen(
        data: (data) => data,
        orElse: () => <String, DiscoveredEventArgs>{},
      );

      final updatedChats = await _chatsRepository.getAllChats(
        nearbyDevices: nearbyDevices,
        discoveryData: discoveryData,
        searchQuery: searchQuery.trim().isEmpty ? null : searchQuery,
        limit: searchQuery.trim().isEmpty ? _pageSize : null,
        offset: 0,
      );
      if (_isDisposed) return;
      if (updatedChats.isEmpty) return;

      // Only touch the chat that changed to avoid UI flicker and excess work.
      final mostRecentChat = updatedChats.first;
      final existingIndex = chats.indexWhere(
        (chat) => chat.chatId == mostRecentChat.chatId,
      );

      if (existingIndex != -1) {
        chats[existingIndex] = mostRecentChat;
        chats.sort((a, b) {
          if (a.isOnline && !b.isOnline) return -1;
          if (!a.isOnline && b.isOnline) return 1;
          final aTime = a.lastMessageTime ?? DateTime(1970);
          final bTime = b.lastMessageTime ?? DateTime(1970);
          return bTime.compareTo(aTime);
        });
      } else {
        chats.insert(0, mostRecentChat);
      }

      _safeNotifyListeners();
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

  bool isChatPinned(ChatId chatId) =>
      _chatManagementService.isChatPinned(chatId);

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
    if (_isDisposed) return;
    try {
      final bleService = ref.read(connectionServiceProvider);

      _globalMessageSubscription = bleService.receivedMessages.listen((
        _,
      ) async {
        _logger.info(
          'Global listener: New message received - updating chat list',
        );
        await updateSingleChatItem();
        _refreshUnreadCount();
      });
    } catch (e) {
      _logger.warning('Failed to set up global message listener: $e');
    }
  }

  Future<List<Peripheral>?> _getNearbyDevices() async {
    final devicesAsync = ref.read(discoveredDevicesProvider);
    return devicesAsync.maybeWhen(
      data: (devices) => devices,
      orElse: () => null,
    );
  }

  void _setupPeripheralConnectionListener() {
    if (_isDisposed) return;
    if (!Platform.isAndroid) return;

    final bleService = ref.read(connectionServiceProvider);

    _peripheralConnectionSubscription = bleService.peripheralConnectionChanges
        .distinct(
          (prev, next) =>
              prev.central.uuid == next.central.uuid &&
              prev.state == next.state,
        )
        .where(
          (event) =>
              bleService.isPeripheralMode &&
              event.state == ble.ConnectionState.connected,
        )
        .listen((event) {
          _handleIncomingPeripheralConnection(event.central);
        });

    _connectionInfoSubscription = bleService.connectionInfo.listen((
      ConnectionInfo _,
    ) {
      _safeNotifyListeners();
    });
  }

  void _setupDiscoveryListener() {
    if (_isDisposed) return;
    _discoveryDataSubscription = ref
        .read(connectionServiceProvider)
        .discoveryData
        .listen((_) {
          if (!isLoading) {
            loadChats();
          }
        });
  }

  void _handleIncomingPeripheralConnection(Central central) {
    _logger.fine('Incoming peripheral connection: ${central.uuid}');
    loadChats();
  }

  void _setupUnreadCountStream() {
    if (_isDisposed) return;
    unreadCountStream = Stream.periodic(const Duration(seconds: 3), (_) {
      return _chatsRepository.getTotalUnreadCount();
    }).asyncMap((futureCount) async => await futureCount);
    _safeNotifyListeners();
  }

  void _refreshUnreadCount() {
    _setupUnreadCountStream();
  }

  bool get isPaging => _isPaging;
  bool get hasMore => _hasMore;

  Future<void> loadMoreChats() async {
    if (_isDisposed || _isPaging || !_hasMore) return;
    _isPaging = true;
    _safeNotifyListeners();
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

  @override
  void dispose() {
    _isDisposed = true;
    _peripheralConnectionSubscription?.cancel();
    _connectionInfoSubscription?.cancel();
    _discoveryDataSubscription?.cancel();
    _globalMessageSubscription?.cancel();
    _chatManagementService.dispose();
    _homeScreenFacade.dispose();
    super.dispose();
  }

  void _safeNotifyListeners() {
    if (_isDisposed) return;
    notifyListeners();
  }
}

final homeScreenControllerProvider = ChangeNotifierProvider.autoDispose
    .family<HomeScreenController, HomeScreenControllerArgs>((ref, args) {
      final controller = HomeScreenController(args);
      unawaited(controller.initialize());
      return controller;
    });
