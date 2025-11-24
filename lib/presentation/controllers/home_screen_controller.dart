import 'dart:async';
import 'dart:io' show Platform;

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' as ble;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../core/discovery/device_deduplication_manager.dart';
import '../../core/interfaces/i_chats_repository.dart';
import '../../core/models/connection_info.dart';
import '../../core/models/connection_status.dart';
import '../../core/services/home_screen_facade.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../domain/services/chat_management_service.dart';
import '../providers/ble_providers.dart';
import '../providers/mesh_networking_provider.dart';

class HomeScreenController extends ChangeNotifier {
  HomeScreenController({
    required this.ref,
    required this.context,
    required IChatsRepository chatsRepository,
    Logger? logger,
    ChatManagementService? chatManagementService,
    HomeScreenFacade? homeScreenFacade,
  }) : _logger = logger ?? Logger('HomeScreenController'),
       _chatsRepository = chatsRepository,
       _chatManagementService =
           chatManagementService ??
           _fallbackChatManagementServiceHolder.instance,
       _homeScreenFacade =
           homeScreenFacade ??
           HomeScreenFacade(
             chatsRepository: chatsRepository,
             bleService: ref.read(connectionServiceProvider),
             chatManagementService:
                 chatManagementService ??
                 _fallbackChatManagementServiceHolder.instance,
             context: context,
             ref: ref,
             enableListCoordinatorInitialization: false,
           );

  // Ensures HomeScreenFacade gets a stable ChatManagementService when one is
  // not provided explicitly.
  static final _fallbackChatManagementServiceHolder =
      _ChatManagementServiceHolder();

  final WidgetRef ref;
  final BuildContext context;
  final Logger _logger;
  final IChatsRepository _chatsRepository;
  final ChatManagementService _chatManagementService;
  final HomeScreenFacade _homeScreenFacade;

  bool _isDisposed = false;
  List<ChatListItem> chats = [];
  bool isLoading = true;
  String searchQuery = '';
  Stream<int>? unreadCountStream;

  Timer? _refreshTimer;
  Timer? _searchDebounceTimer;
  StreamSubscription? _peripheralConnectionSubscription;
  StreamSubscription? _connectionInfoSubscription;
  StreamSubscription? _discoveryDataSubscription;
  StreamSubscription? _globalMessageSubscription;

  Future<void> initialize() async {
    if (_isDisposed) return;
    await _chatManagementService.initialize();
    if (_isDisposed) return;
    await _homeScreenFacade.initialize();
    if (_isDisposed) return;
    await loadChats();
    if (_isDisposed) return;
    _setupPeriodicRefresh();
    _setupPeripheralConnectionListener();
    _setupDiscoveryListener();
    _setupUnreadCountStream();
    _setupGlobalMessageListener();
  }

  Future<void> loadChats() async {
    if (_isDisposed) return;
    if (isLoading) {
      _safeNotifyListeners();
    }

    final nearbyDevices = await _getNearbyDevices();
    if (_isDisposed) return;
    final discoveryDataAsync = ref.read(discoveryDataProvider);
    final discoveryData = discoveryDataAsync.maybeWhen(
      data: (data) => data,
      orElse: () => <String, DiscoveredEventArgs>{},
    );

    final results = await _chatsRepository.getAllChats(
      nearbyDevices: nearbyDevices,
      discoveryData: discoveryData,
      searchQuery: searchQuery.trim().isEmpty ? null : searchQuery,
    );

    if (_isDisposed) return;
    chats = results;
    isLoading = false;
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
      _searchDebounceTimer?.cancel();
      loadChats();
      return;
    }

    searchQuery = query;
    _safeNotifyListeners();
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      loadChats();
    });
  }

  void clearSearch() {
    if (_isDisposed) return;
    searchQuery = '';
    _searchDebounceTimer?.cancel();
    loadChats();
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

  bool isChatPinned(String chatId) =>
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

  void _setupPeriodicRefresh() {
    if (_isDisposed) return;
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!isLoading) {
        loadChats();
      }
    });
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
    _refreshTimer?.cancel();
    _searchDebounceTimer?.cancel();
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

class _ChatManagementServiceHolder {
  _ChatManagementServiceHolder();
  final ChatManagementService instance = ChatManagementService();
}
