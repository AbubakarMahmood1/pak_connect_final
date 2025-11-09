// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import '../providers/ble_providers.dart';
import '../providers/security_state_provider.dart';
import '../providers/mesh_networking_provider.dart';
import '../../domain/services/mesh_networking_service.dart';
import '../../domain/entities/message.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../data/repositories/message_repository.dart';
import '../../data/repositories/chats_repository.dart';
import '../../core/utils/chat_utils.dart';
import '../widgets/message_bubble.dart';
import '../widgets/chat_search_bar.dart';
import '../../core/models/connection_info.dart';
import '../widgets/pairing_dialog.dart';
import '../../core/services/simple_crypto.dart';
import '../../core/models/security_state.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/services/security_manager.dart';
import '../../core/services/persistent_chat_state_manager.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/services/message_retry_coordinator.dart';
import '../../core/app_core.dart';
import '../../core/security/message_security.dart';
import '../../domain/services/notification_service.dart';
import '../../core/messaging/message_router.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final Peripheral? device; // For central mode (live connection)
  final Central? central; // For peripheral mode (live connection)
  final String? chatId; // For repository mode (stored data)
  final String? contactName; // Contact display name
  final String? contactPublicKey; // Contact public key

  const ChatScreen({
    super.key,
    this.device,
    this.central,
    this.chatId,
    this.contactName,
    this.contactPublicKey,
  }) : assert(
         (device != null || central != null) ||
             (chatId != null && contactName != null),
         'Either live connection (device/central) OR chat data (chatId/contactName) must be provided',
       );

  // Named constructor for repository-based chats
  const ChatScreen.fromChatData({
    super.key,
    required String this.chatId,
    required String this.contactName,
    required String this.contactPublicKey,
  }) : device = null,
       central = null;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _logger = Logger('ChatScreen');
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final MessageRepository _messageRepository = MessageRepository();
  late final MessageRetryCoordinator _retryCoordinator;
  static final Map<String, SecurityState> _securityStateCache = {};

  List<Message> _messages = [];
  bool _isLoading = true;
  bool _pairingDialogShown = false;
  bool _contactRequestInProgress = false;
  StreamSubscription<String>? _messageSubscription;
  StreamSubscription<String>?
  _deliverySubscription; // 🎯 Real-time delivery updates
  bool _messageListenerActive = false;
  final List<String> _messageBuffer = [];
  PersistentChatStateManager? _persistentChatManager;
  String? _currentChatId;
  int _unreadMessageCount = 0;
  int _lastReadMessageIndex = -1;
  bool _showUnreadSeparator = false;
  Timer? _unreadSeparatorTimer;

  // 🔥 WhatsApp-style smart unread handling
  bool _isUserAtBottom = true; // Track if user is scrolled to bottom
  int _newMessagesWhileScrolledUp =
      0; // Count of new messages received while scrolled up
  Timer?
  _markAsReadDebounceTimer; // Debounce timer for marking messages as read
  bool _hasScrolledAwayFromBottom =
      false; // Track if user intentionally scrolled up

  // Search state
  bool _isSearchMode = false;
  String _searchQuery = '';

  // Smart routing demo state
  bool _demoModeEnabled = true; // Auto-enable demo mode
  StreamSubscription? _meshEventSubscription;
  bool _meshInitializing = false; // 🔧 FIX: Start false, check actual state
  String _initializationStatus = 'Checking...';
  Timer? _initializationTimeoutTimer;

  // 🔧 FIX: Cache contact public key to avoid accessing ref during dispose
  String? _cachedContactPublicKey;

  /// 🔧 FIX: Safe setState that checks mounted before calling
  void _safeSetState(VoidCallback fn) {
    if (mounted) {
      setState(fn);
    }
  }

  String get _chatId => _currentChatId!;
  bool get _isPeripheralMode => widget.central != null;
  bool get _isCentralMode => widget.device != null;
  bool get _isRepositoryMode => widget.chatId != null;

  String get _displayContactName {
    if (_isRepositoryMode) return widget.contactName!;
    if (_isCentralMode && widget.device != null) {
      return widget.device!.uuid.toString().shortId(8);
    }
    if (_isPeripheralMode && widget.central != null) {
      return widget.central!.uuid.toString().shortId(8);
    }
    return 'Unknown';
  }

  /// Get the current contact public key - single source of truth
  /// This reactively reads from BLE service, so it automatically updates
  /// when pairing completes and persistent keys are exchanged
  String? get _contactPublicKey {
    if (_isRepositoryMode) {
      return widget.contactPublicKey;
    }

    // 🔧 FIX: Return cached value if widget is unmounting (prevents dispose crash)
    if (!mounted) {
      return _cachedContactPublicKey;
    }

    // Live connection: Use BLE service's currentSessionId
    // This is ephemeral ID initially, then becomes persistent key after pairing
    final bleService = ref.read(bleServiceProvider);
    final currentKey = bleService.currentSessionId;

    // Cache the value for safe access during dispose
    _cachedContactPublicKey = currentKey;

    return currentKey;
  }

  String? get securityStateKey {
    final publicKey = widget.contactPublicKey ?? _contactPublicKey;

    if (publicKey != null && publicKey.isNotEmpty) {
      // Force repository lookup for all known contacts
      return 'repo_$publicKey';
    }

    // Only use live mode for truly unknown connections
    final bleService = ref.read(bleServiceProvider);
    return bleService.currentSessionId;
  }

  @override
  void initState() {
    super.initState();
    print('🐛 NAV DEBUG: ChatScreen initState() called');
    print('🐛 NAV DEBUG: - widget.device: ${widget.device?.uuid}');
    print('🐛 NAV DEBUG: - widget.central: ${widget.central?.uuid}');
    print('🐛 NAV DEBUG: - widget.chatId: ${widget.chatId}');
    print('🐛 NAV DEBUG: - widget.contactName: ${widget.contactName}');
    print(
      '🐛 NAV DEBUG: - widget.contactPublicKey: ${widget.contactPublicKey != null && widget.contactPublicKey!.length > 16 ? '${widget.contactPublicKey!.shortId()}...' : widget.contactPublicKey ?? 'null'}',
    );

    _currentChatId = _calculateInitialChatId();
    print('🐛 NAV DEBUG: - calculated chatId: $_currentChatId');

    // 💬🔑 COMPREHENSIVE CHAT OPEN LOGGING (search: 💬🔑)
    _logChatOpenState();

    _loadMessages();
    _loadUnreadCount();

    _setupPersistentChatManager();
    _checkAndSetupLiveMessaging();
    _setupMeshNetworking();
    _setupDeliveryListener(); // 🎯 Real-time status updates
    _initializeRetryCoordinator();

    _setupSecurityStateListener();
    _setupScrollListener(); // 🔥 WhatsApp-style scroll position tracking
    print('🐛 NAV DEBUG: ChatScreen initState() completed');
  }

  Future<void> _logChatOpenState() async {
    final contactRepo = ContactRepository();
    final publicKey = widget.contactPublicKey ?? _currentChatId;

    if (publicKey == null) {
      _logger.warning('💬🔑 CHAT OPEN: No public key available');
      return;
    }

    final contact = await contactRepo.getContact(publicKey);
    final securityLevel = await SecurityManager.getCurrentLevel(
      publicKey,
      contactRepo,
    );
    final encryptionMethod = await SecurityManager.getEncryptionMethod(
      publicKey,
      contactRepo,
    );

    _logger.info(
      '💬🔑 CHAT OPEN: ${widget.contactName ?? "Unknown"} | Security=${securityLevel.name} | Encryption=${encryptionMethod.type.name}',
    );
    final pkDisp = publicKey.length > 16
        ? '${publicKey.shortId()}...'
        : publicKey;
    final eph = contact?.currentEphemeralId;
    final ephDisp = eph != null
        ? (eph.length > 16 ? '${eph.shortId()}...' : eph)
        : 'NULL';
    final sid = contact?.sessionIdForNoise;
    final sidDisp = sid != null
        ? (sid.length > 16 ? '${sid.shortId()}...' : sid)
        : 'NULL';
    _logger.info(
      '💬🔑 Keys: PubKey=$pkDisp | CurrentEphemeralID=$ephDisp | NoiseSession=$sidDisp',
    );
  }

  void _checkAndSetupLiveMessaging() {
    final connectionInfo = ref.read(connectionInfoProvider).value;

    if (connectionInfo?.isConnected == true) {
      _setupMessageListener();
      _setupContactRequestListener();
      _logger.info('✅ Live messaging enabled - BLE connection detected');
    } else {
      _logger.info('📦 Repository mode only - no BLE connection');
    }
  }

  /// Set up mesh networking integration with auto demo mode
  void _setupMeshNetworking() {
    try {
      _logger.info(
        'Setting up mesh networking for chat screen with auto demo mode',
      );

      // 🔧 FIX: Check current mesh state before showing banner
      final meshStatusAsync = ref.read(meshNetworkStatusProvider);
      meshStatusAsync.when(
        data: (status) {
          if (status.isInitialized) {
            // Mesh already initialized - no banner needed
            setState(() {
              _meshInitializing = false;
              _demoModeEnabled = true;
              _initializationStatus = 'Ready - Demo Mode Active';
            });
            _logger.info('✅ Mesh already initialized - skipping banner');
          } else {
            // Mesh still initializing - show banner with timeout
            setState(() {
              _meshInitializing = true;
              _initializationStatus = 'Initializing mesh network...';
            });
            _startInitializationTimeoutTimer();
            _logger.info(
              '🔄 Mesh still initializing - showing banner with timeout',
            );
          }
        },
        loading: () {
          // Mesh status unknown - show banner briefly
          setState(() {
            _meshInitializing = true;
            _initializationStatus = 'Checking mesh status...';
          });
          _startInitializationTimeoutTimer();
          _logger.info(
            '🔍 Mesh status unknown - showing banner with short timeout',
          );
        },
        error: (error, stack) {
          // Error getting status - don't show banner
          setState(() {
            _meshInitializing = false;
            _initializationStatus = 'Mesh ready (fallback)';
          });
          _logger.warning('⚠️ Mesh status error - skipping banner: $error');
        },
      );

      // Listen to mesh demo events for UI feedback
      final meshService = ref.read(meshNetworkingServiceProvider);
      _meshEventSubscription = meshService.demoEvents.listen((event) {
        if (!mounted) return;

        // Handle different demo event types
        _handleMeshDemoEvent(event);
      });

      // Note: Mesh initialization monitoring moved to build() method to comply with Riverpod rules
      _logger.info('Mesh networking integration set up with auto demo mode');
    } catch (e) {
      _logger.warning('Failed to set up mesh networking: $e');
      setState(() {
        _meshInitializing = false;
        _initializationStatus = 'Failed to initialize';
      });
    }
  }

  /// 🎯 Setup real-time delivery listener for instant status updates (no flicker)
  void _setupDeliveryListener() {
    try {
      final meshService = ref.read(meshNetworkingServiceProvider);

      _deliverySubscription = meshService.messageDeliveryStream.listen((
        messageId,
      ) {
        if (!mounted) return;

        // Surgical update: find the message and update only its status
        _updateMessageStatus(messageId, MessageStatus.delivered);
      });

      _logger.info('✅ Real-time delivery listener set up');
    } catch (e) {
      _logger.warning('⚠️ Failed to set up delivery listener: $e');
      // Not critical - messages will still update on chat reopen
    }
  }

  /// Surgically update a specific message status (prevents UI flicker)
  void _updateMessageStatus(String messageId, MessageStatus newStatus) {
    final index = _messages.indexWhere((m) => m.id == messageId);

    if (index != -1) {
      setState(() {
        _messages[index] = _messages[index].copyWith(status: newStatus);
      });

      _logger.fine(
        '🎯 Updated message ${messageId.shortId()}... status to ${newStatus.name}',
      );
    } else {
      _logger.fine(
        '⚠️ Message ${messageId.shortId()}... not found in current UI (may have been from different chat)',
      );
    }
  }

  /// 🔥 Setup WhatsApp-style scroll position tracking
  void _setupScrollListener() {
    _scrollController.addListener(_onScroll);
    _logger.info('✅ Scroll position listener set up for smart unread handling');
  }

  /// Handle scroll position changes for smart unread count management
  void _onScroll() {
    if (!_scrollController.hasClients || !mounted) return;

    final scrollPosition = _scrollController.position;
    final maxScroll = scrollPosition.maxScrollExtent;
    final currentScroll = scrollPosition.pixels;

    // Consider "at bottom" if within 100 pixels of bottom
    const bottomThreshold = 100.0;
    final atBottom = (maxScroll - currentScroll) < bottomThreshold;

    // Detect if user scrolled away from bottom
    if (_isUserAtBottom && !atBottom) {
      setState(() {
        _hasScrolledAwayFromBottom = true;
      });
      _logger.fine('📜 User scrolled away from bottom');
    }

    // Update bottom status
    if (_isUserAtBottom != atBottom) {
      setState(() {
        _isUserAtBottom = atBottom;
      });

      // If user returned to bottom, mark messages as read after short delay
      if (atBottom) {
        _logger.fine('📜 User returned to bottom - scheduling mark as read');
        _scheduleMarkAsRead();
      }
    }
  }

  /// Schedule marking messages as read (debounced for 1.5 seconds at bottom)
  void _scheduleMarkAsRead() {
    // Cancel existing timer
    _markAsReadDebounceTimer?.cancel();

    // Only schedule if there are new messages to mark as read
    if (_newMessagesWhileScrolledUp > 0 || _unreadMessageCount > 0) {
      _markAsReadDebounceTimer = Timer(Duration(milliseconds: 1500), () {
        if (mounted && _isUserAtBottom) {
          _logger.info('✅ User stayed at bottom - marking messages as read');
          _decrementUnreadCount();
        }
      });
    }
  }

  /// Decrement unread count (WhatsApp-style)
  Future<void> _decrementUnreadCount() async {
    if (_newMessagesWhileScrolledUp > 0 || _unreadMessageCount > 0) {
      final chatsRepo = ChatsRepository();
      await chatsRepo.markChatAsRead(_chatId);

      _safeSetState(() {
        _newMessagesWhileScrolledUp = 0;
        _unreadMessageCount = 0;
        _hasScrolledAwayFromBottom = false;
      });

      _logger.info('📊 Unread count reset to 0');
    }
  }

  /// Determine if scroll-down button should be shown
  bool _shouldShowScrollDownButton() {
    // Show button if:
    // 1. User has scrolled away from bottom AND
    // 2. There are messages (prevents showing on empty chat) AND
    // 3. Either there are new unread messages OR user has scrolled significantly up
    return !_isUserAtBottom &&
        _messages.isNotEmpty &&
        (_newMessagesWhileScrolledUp > 0 || _hasScrolledAwayFromBottom);
  }

  /// Start timeout timer to prevent persistent initialization banner
  void _startInitializationTimeoutTimer() {
    _initializationTimeoutTimer?.cancel();

    // Use shorter timeout for status checking, longer for actual initialization
    final timeoutDuration = _initializationStatus.contains('Checking')
        ? Duration(seconds: 3) // Quick timeout for status check
        : Duration(seconds: 15); // Normal timeout for initialization

    _initializationTimeoutTimer = Timer(timeoutDuration, () {
      if (mounted && _meshInitializing) {
        _logger.info(
          '🕐 Mesh initialization timeout reached - forcing banner to hide',
        );
        setState(() {
          _meshInitializing = false;
          _initializationStatus = 'Ready (timeout fallback)';
          _demoModeEnabled = true; // Enable demo mode as fallback
        });
        _showSuccess('Mesh networking ready (fallback mode)');
      }
    });
  }

  /// Handle mesh initialization status changes (logic only, no ref.listen)
  void _handleMeshInitializationStatusChange(
    AsyncValue<MeshNetworkStatus>? previous,
    AsyncValue<MeshNetworkStatus> next,
  ) {
    if (!mounted) return;

    next.when(
      data: (status) {
        if (status.isInitialized && _meshInitializing) {
          // 🔧 NEW: Cancel timeout timer since proper initialization completed
          _initializationTimeoutTimer?.cancel();
          setState(() {
            _meshInitializing = false;
            _demoModeEnabled = true;
            _initializationStatus = 'Ready - Demo Mode Active';
          });
          _logger.info(
            '✅ Mesh networking initialized - Demo mode automatically enabled',
          );
          _showSuccess('🎓 Smart routing demo mode activated');
        } else if (!status.isInitialized && !_meshInitializing) {
          setState(() {
            _initializationStatus = status.isDemoMode
                ? 'Demo Mode Ready'
                : 'Initializing...';
          });
        }
      },
      loading: () {
        if (!_meshInitializing) {
          setState(() {
            _meshInitializing = true;
            _initializationStatus = 'Initializing mesh network...';
          });
        }
      },
      error: (error, stack) {
        setState(() {
          _meshInitializing = false;
          _initializationStatus = 'Initialization failed';
        });
        _logger.severe('Mesh initialization error: $error');
      },
    );
  }

  void _setupSecurityStateListener() {
    final bleService = ref.read(bleServiceProvider);

    bleService.stateManager.onContactRequestCompleted = (success) {
      if (!mounted) return;
      _logger.info(
        'Contact operation completed: $success - refreshing UI state',
      );

      if (success) {
        Timer(Duration(milliseconds: 500), () {
          if (mounted) {
            ref.invalidate(securityStateProvider(securityStateKey));
          }
        });
      }
    };
  }

  void _userRequestedPairing() async {
    if (_pairingDialogShown) return;

    final connectionInfo = ref.read(connectionInfoProvider).value;
    if (!(connectionInfo?.isConnected ?? false)) {
      _showError('Not connected - cannot pair');
      return;
    }

    print('🔑 USER: User requested pairing dialog');
    _pairingDialogShown = true;
    _showPairingDialog();
  }

  void _showPairingDialog() async {
    final bleService = ref.read(bleServiceProvider);
    bleService.connectionManager.setPairingInProgress(true);
    bleService.stateManager.clearPairing();

    final myCode = bleService.stateManager.generatePairingCode();

    // Capture context before async
    final navigator = Navigator.of(context);

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PairingDialog(
        myCode: myCode,
        onCodeEntered: (theirCode) async {
          final success = await bleService.stateManager.completePairing(
            theirCode,
          );
          if (mounted) navigator.pop(success);
        },
        onCancel: () {
          if (mounted) navigator.pop(false);
        },
      ),
    );

    // Resume health checks after pairing
    bleService.connectionManager.setPairingInProgress(false);

    if (result == true) {
      print('🛠 DEBUG: Pairing completed successfully in chat screen');

      final otherKey = bleService.theirPersistentKey;
      if (otherKey != null) {
        print('🛠 DEBUG: Attempting security upgrade for: $otherKey');
        final upgradeResult = await bleService.stateManager
            .confirmSecurityUpgrade(otherKey, SecurityLevel.medium);
        print('🛠 DEBUG: Security upgrade result: $upgradeResult');
      }

      _logger.info('Pairing successful - keeping session active');
    } else {
      print('🛠 DEBUG: Pairing failed or cancelled');
      bleService.stateManager.clearPairing();
    }

    _pairingDialogShown = false;
  }

  void _handleAsymmetricContact(String publicKey, String displayName) {
    // Only show if we're not already handling this
    if (_contactRequestInProgress) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.sync_problem, color: Colors.orange),
            SizedBox(width: 8),
            Text('Contact Sync'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$displayName has you as a verified contact, but you haven\'t added them back yet.',
            ),
            SizedBox(height: 12),
            Text('Add them to enable secure ECDH encryption?'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Not Now'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await _addAsVerifiedContact(publicKey, displayName);
            },
            child: Text('Add Contact'),
          ),
        ],
      ),
    );
  }

  Future<void> _addAsVerifiedContact(
    String publicKey,
    String displayName,
  ) async {
    try {
      final contactRepo = ContactRepository();
      await contactRepo.saveContact(publicKey, displayName);
      await contactRepo.markContactVerified(publicKey);

      // Compute and cache ECDH shared secret
      final sharedSecret = SimpleCrypto.computeSharedSecret(publicKey);
      if (sharedSecret != null) {
        await contactRepo.cacheSharedSecret(publicKey, sharedSecret);

        // Also restore it in SimpleCrypto for immediate use
        await SimpleCrypto.restoreConversationKey(publicKey, sharedSecret);
      }

      _logger.info('Added asymmetric contact as verified: $displayName');
    } catch (e) {
      _logger.severe('Failed to add verified contact: $e');
    }
  }

  Future<void> _manualReconnection() async {
    final bleService = ref.read(bleServiceProvider);

    // Check if already connected
    if (bleService.isConnected) {
      _showSuccess('Already connected');
      return;
    }

    _showSuccess('Manually searching for device...');

    try {
      final foundDevice = await bleService.scanForSpecificDevice(
        timeout: Duration(seconds: 10),
      );

      if (foundDevice != null) {
        // Check if this is the same device we're already connected to
        if (bleService.connectedDevice?.uuid == foundDevice.uuid) {
          _showSuccess('Already connected to this device');
          return;
        }

        await bleService.connectToDevice(foundDevice);
        _showSuccess('Manual reconnection successful!');
      } else {
        _showError(
          'Device not found - ensure other device is in discoverable mode',
        );
      }
    } catch (e) {
      // Better error handling for already connected case
      final errorMsg = e.toString();
      if (errorMsg.contains('1049')) {
        _showSuccess('Already connected to device');
      } else {
        _showError('Manual reconnection failed: ${errorMsg.split(':').last}');
      }
    }
  }

  // REMOVED: _initializePersistentValues() - no longer needed
  // The _contactPublicKey getter reactively reads from BLE service
  // This automatically gives us the correct key (ephemeral or persistent) at any moment

  /// Check if there are messages queued for relay that should prevent disconnection
  bool _hasMessagesQueuedForRelay() {
    try {
      // Use singleton from AppCore instead of creating new instance
      final offlineQueue = AppCore.instance.messageQueue;
      final queuedMessages = offlineQueue.getPendingMessages();

      // Check if any queued messages are for this chat and intended for relay
      final chatMessages = queuedMessages.where(
        (msg) => msg.recipientPublicKey == _contactPublicKey,
      );

      if (chatMessages.isNotEmpty) {
        _logger.info(
          '🔄 Found ${chatMessages.length} messages queued for relay in this chat',
        );
        return true;
      }

      return false;
    } catch (e) {
      _logger.warning('Error checking relay queue: $e');
      return false;
    }
  }

  Future<void> _loadMessages() async {
    // 🔧 OPTION B: Load from BOTH queue (in-flight) and repository (delivered)

    // 1. Load delivered messages from repository (permanent history)
    final deliveredMessages = await _messageRepository.getMessages(_chatId);

    // 2. Load in-flight messages from queue (pending delivery)
    final meshService = ref.read(meshNetworkingServiceProvider);
    final queuedMessages = meshService.getQueuedMessagesForChat(_chatId);

    // 3. Convert queued messages to Message objects for UI display
    final pendingMessages = queuedMessages
        .map(
          (qm) => Message(
            id: qm.id,
            chatId: qm.chatId,
            content: qm.content,
            timestamp: qm.queuedAt,
            isFromMe: true, // Queued messages are always outgoing
            status: _mapQueuedStatus(qm.status),
          ),
        )
        .toList();

    // 4. 🔧 FIX: Deduplicate by message ID (delivered messages take precedence)
    // When a message is delivered, it's in BOTH repository and queue temporarily
    final deliveredIds = deliveredMessages.map((m) => m.id).toSet();
    final uniquePending = pendingMessages
        .where((m) => !deliveredIds.contains(m.id))
        .toList();

    // 5. Merge both lists and sort by timestamp
    final allMessages = [...deliveredMessages, ...uniquePending];
    allMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    setState(() {
      _messages = allMessages;
      _isLoading = false;
    });
    _scrollToBottom();

    _logger.info(
      '📋 Loaded ${deliveredMessages.length} delivered + ${uniquePending.length} pending = ${allMessages.length} total messages (${pendingMessages.length - uniquePending.length} duplicates removed)',
    );

    // Process any buffered messages from previous lifecycle
    await _processBufferedMessages();

    // Auto-retry failed messages after a short delay
    Future.delayed(Duration(milliseconds: 1000), () {
      if (mounted) {
        _autoRetryFailedMessages();
      }
    });
  }

  /// Map queue status to UI status
  MessageStatus _mapQueuedStatus(QueuedMessageStatus queueStatus) {
    switch (queueStatus) {
      case QueuedMessageStatus.pending:
        return MessageStatus.sending;
      case QueuedMessageStatus.sending:
        return MessageStatus.sending;
      case QueuedMessageStatus.retrying:
        return MessageStatus
            .sending; // Show as sending (or could add MessageStatus.retrying)
      case QueuedMessageStatus.failed:
        return MessageStatus.failed;
      case QueuedMessageStatus.delivered:
        return MessageStatus.delivered;
      default:
        return MessageStatus.sent;
    }
  }

  /// Initialize the retry coordinator for coordinated message retry across both systems
  void _initializeRetryCoordinator() {
    try {
      // Access the offline message queue through mesh networking service
      final meshService = ref.read(meshNetworkingServiceProvider);

      // Use singleton from AppCore instead of creating new instance
      final offlineQueue = AppCore.instance.messageQueue;

      _retryCoordinator = MessageRetryCoordinator(
        messageRepository: _messageRepository,
        offlineQueue: offlineQueue,
        meshService: meshService,
      );

      _logger.info('✅ MessageRetryCoordinator initialized successfully');
    } catch (e) {
      _logger.warning('⚠️ Failed to initialize MessageRetryCoordinator: $e');
      // Will fallback to individual system retries
    }
  }

  /// Unified retry system using the MessageRetryCoordinator
  Future<void> _autoRetryFailedMessages() async {
    try {
      _logger.info(
        '🔄 Starting coordinated retry using MessageRetryCoordinator',
      );

      // Get the connection info but be less strict about connectivity
      final connectionInfo = ref.read(connectionInfoProvider).value;
      final isConnected = connectionInfo?.isConnected ?? false;

      // Show initial feedback
      if (!isConnected) {
        _logger.info(
          '⚠️ Connection not established but proceeding with retry - coordinator will handle queuing',
        );
        _showSuccess(
          'Attempting retry - messages will be queued if connection fails...',
        );
      } else {
        _showSuccess('Connection available - retrying failed messages...');
      }

      // Use the coordinator to get unified retry status
      final retryStatus = await _retryCoordinator.getFailedMessageStatus(
        _chatId,
      );

      if (retryStatus.hasError) {
        _logger.warning('⚠️ Error getting retry status: ${retryStatus.error}');
        _showError('Failed to check message status - ${retryStatus.error}');
        return;
      }

      if (!retryStatus.hasFailedMessages) {
        _logger.info('✅ No failed messages found in either persistence system');
        return;
      }

      _logger.info(
        '🎯 Coordinator found ${retryStatus.totalFailed} total failed messages to retry',
      );
      _showSuccess(
        'Retrying ${retryStatus.totalFailed} failed message${retryStatus.totalFailed > 1 ? 's' : ''}...',
      );

      // Use coordinated retry with proper callback functions
      final retryResult = await _retryCoordinator.retryAllFailedMessages(
        chatId: _chatId,
        allowPartialConnection: true,
        onRepositoryMessageRetry: (Message message) async {
          // Handle repository message retry
          await _retryRepositoryMessage(message);
        },
        onQueueMessageRetry: (QueuedMessage queuedMessage) async {
          // Handle queue message retry - delegate to queue system
          _logger.info(
            '📤 Delegating queue message retry to OfflineMessageQueue',
          );
        },
      );

      // Update UI based on results
      _scrollToBottom();

      // Show coordinated completion status
      final stillFailed = _messages
          .where((m) => m.isFromMe && m.status == MessageStatus.failed)
          .length;

      if (retryResult.success && retryResult.totalSucceeded > 0) {
        _showSuccess('✅ ${retryResult.message}');
      } else if (stillFailed > 0) {
        _showError('⚠️ ${retryResult.message}');
      } else {
        _showSuccess('✅ All messages processed - ${retryResult.message}');
      }

      _logger.info(
        '🏁 Coordinated retry completed: ${retryResult.totalSucceeded}/${retryResult.totalAttempted} succeeded',
      );
    } catch (e) {
      _logger.severe('💥 Coordinated retry system encountered an error: $e');
      _showError('Retry coordination error - falling back to individual retry');

      // Fallback to the old individual retry system
      await _fallbackRetryFailedMessages();
    }
  }

  /// Retry a repository message with enhanced delivery strategies
  Future<void> _retryRepositoryMessage(Message message) async {
    try {
      _logger.info(
        '🔄 Retrying repository message: ${message.id.shortId(8)}... - "${message.content.substring(0, min(20, message.content.length))}..."',
      );

      // Update to sending status with optimistic UI update
      final retryMessage = message.copyWith(status: MessageStatus.sending);
      await _messageRepository.updateMessage(retryMessage);
      _safeSetState(() {
        final index = _messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          _messages[index] = retryMessage;
        }
      });

      bool success = false;
      final connectionInfo = ref.read(connectionInfoProvider).value;
      final isConnected = connectionInfo?.isConnected ?? false;
      final isReady = connectionInfo?.isReady ?? false;

      // Enhanced delivery attempt using MessageRouter (BitChat pattern)
      // MessageRouter handles offline queueing automatically
      try {
        final router = MessageRouter.instance;
        final result = await router.sendMessage(
          content: message.content,
          recipientId: _contactPublicKey ?? _chatId,
          messageId: message.id,
          recipientName: _displayContactName,
        );

        success = result.isSentDirectly;

        if (result.isQueued) {
          _logger.info(
            '📮 Message retry queued (peer offline) - will auto-send when online',
          );
          _showInfo('Message queued - will send when peer comes online');
        } else if (success) {
          _logger.info('📡 Message retry sent directly');
        }
      } catch (e) {
        _logger.warning(
          'MessageRouter retry failed: $e - falling back to direct BLE',
        );

        // Fallback to direct BLE if MessageRouter unavailable
        if (isConnected && isReady) {
          final bleService = ref.read(bleServiceProvider);

          if (_isCentralMode) {
            success = await bleService.sendMessage(
              message.content,
              messageId: message.id,
            );
          } else {
            success = await bleService.sendPeripheralMessage(
              message.content,
              messageId: message.id,
            );
          }

          _logger.info('📡 Direct BLE fallback result: $success');
        }
      }

      // If direct delivery failed or not connected, try smart routing (if demo enabled)
      if (!success && _demoModeEnabled && _contactPublicKey != null) {
        try {
          final meshController = ref.read(meshNetworkingControllerProvider);
          final meshResult = await meshController.sendMeshMessage(
            content: message.content,
            recipientPublicKey: _contactPublicKey!,
            isDemo: _demoModeEnabled,
          );

          if (meshResult.isSuccess) {
            success = true;
            _logger.info(
              '🧠 Smart routing retry successful for message ${message.id.shortId(8)}',
            );
          }
        } catch (e) {
          _logger.warning('⚠️ Smart routing retry failed: $e');
        }
      }

      // Update message status based on result
      final newStatus = success
          ? MessageStatus.delivered
          : MessageStatus.failed;
      final updatedMessage = retryMessage.copyWith(status: newStatus);
      await _messageRepository.updateMessage(updatedMessage);
      _safeSetState(() {
        final index = _messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          _messages[index] = updatedMessage;
        }
      });
    } catch (e) {
      // Mark as failed again and continue
      _logger.severe(
        '❌ Repository message retry failed for ${message.id.shortId(8)}: $e',
      );
      final failedAgain = message.copyWith(status: MessageStatus.failed);
      await _messageRepository.updateMessage(failedAgain);
      _safeSetState(() {
        final index = _messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          _messages[index] = failedAgain;
        }
      });
      rethrow; // Let coordinator handle the failure
    }
  }

  /// Fallback retry mechanism if coordinator fails
  Future<void> _fallbackRetryFailedMessages() async {
    _logger.warning('🔄 Using fallback retry mechanism');

    // Simple retry of repository messages only
    final failedMessages = _messages
        .where((m) => m.isFromMe && m.status == MessageStatus.failed)
        .toList();

    if (failedMessages.isEmpty) {
      _logger.info('✅ No repository failed messages to retry in fallback mode');
      return;
    }

    int successCount = 0;
    for (final message in failedMessages) {
      try {
        await _retryRepositoryMessage(message);
        successCount++;
      } catch (e) {
        _logger.warning('⚠️ Fallback retry failed for message: $e');
      }

      // Add delay between retries
      await Future.delayed(Duration(milliseconds: 500));
    }

    if (successCount > 0) {
      _showSuccess(
        '✅ Fallback retry delivered $successCount message${successCount > 1 ? 's' : ''}',
      );
    } else {
      _showError(
        '⚠️ Fallback retry failed - messages will retry automatically when connection improves',
      );
    }
  }

  void _setupPersistentChatManager() {
    print('🟣🟣🟣 _setupPersistentChatManager CALLED 🟣🟣🟣');
    print('🟣 Chat ID: $_chatId');

    _persistentChatManager = ref.read(persistentChatStateManagerProvider);

    print('🟣 Debug info before registration:');
    print('🟣 ${_persistentChatManager!.getDebugInfo()}');

    // Register this chat screen with the persistent manager
    _persistentChatManager!.registerChatScreen(
      _chatId,
      _handlePersistentMessage,
    );

    print('� Debug info after registration:');
    print('🟣 ${_persistentChatManager!.getDebugInfo()}');
    print('🟣 ✅ Registered with PersistentChatStateManager for $_chatId');
  }

  void _handlePersistentMessage(String content) async {
    print(
      '🐛 NAV DEBUG: Received message through persistent manager: ${content.length} chars',
    );
    await _addReceivedMessage(content);
  }

  void _activateMessageListener() {
    if (_messageListenerActive) {
      print(
        '🔵🔵🔵 _activateMessageListener: ALREADY ACTIVE - SKIPPING 🔵🔵🔵',
      );
      return;
    }

    print('�🔵🔵 _activateMessageListener: SETTING UP LISTENER 🔵🔵🔵');
    print('🔵 Chat ID: $_chatId');
    print('🔵 Has persistent manager: ${_persistentChatManager != null}');
    print(
      '🔵 Persistent manager has listener: ${_persistentChatManager?.hasActiveListener(_chatId) ?? false}',
    );

    _messageListenerActive = true;

    final bleService = ref.read(bleServiceProvider);

    // Use persistent manager if available, otherwise fall back to direct subscription
    if (_persistentChatManager != null &&
        !_persistentChatManager!.hasActiveListener(_chatId)) {
      print('� ✅ Setting up persistent listener through manager');
      _persistentChatManager!.setupPersistentListener(
        _chatId,
        bleService.receivedMessages,
      );
    } else if (_persistentChatManager != null &&
        _persistentChatManager!.hasActiveListener(_chatId)) {
      print('� ℹ️ Persistent listener already exists - using existing');
    } else {
      print(
        '🔵 ⚠️ Using direct message subscription (FALLBACK - POTENTIAL DOUBLE SUBSCRIPTION!)',
      );
      _messageSubscription = bleService.receivedMessages.listen((content) {
        print('🔵 📨 Direct subscription received message');
        if (mounted && _messageListenerActive) {
          _addReceivedMessage(content);
        } else if (!mounted) {
          // Buffer message if screen is being disposed/recreated
          _messageBuffer.add(content);
          print(
            '🐛 NAV DEBUG: Message buffered during disposal: ${content.length} chars',
          );
        }
      });
    }
  }

  void _setupMessageListener() {
    // Legacy method - now handled by persistent listener
    _activateMessageListener();
  }

  Future<void> _addReceivedMessage(String content) async {
    print('🔴🔴🔴 _addReceivedMessage CALLED 🔴🔴🔴');
    print('🔴 Stack trace: ${StackTrace.current}');
    print('🔴 Content length: ${content.length}');
    print(
      '🔴 Content preview: ${content.substring(0, content.length > 100 ? 100 : content.length)}',
    );

    // Generate secure message ID for received message (consistent with send flow)
    // Note: For received messages, we use the sender's key (their public key)
    final senderPublicKey =
        _contactPublicKey ?? _chatId; // Use contact key or chatId as fallback
    final secureMessageId = await MessageSecurity.generateSecureMessageId(
      senderPublicKey: senderPublicKey,
      content: content,
    );

    print('🔴 Generated message ID: ${secureMessageId.shortId()}...');

    // �🔑 COMPREHENSIVE RECEIVE LOGGING (search: 📥🔑)
    await _logMessageReceiveState(senderPublicKey, content, secureMessageId);

    // �🔧 FIX: Check repository for duplicate BEFORE saving
    final existingMessage = await _messageRepository.getMessageById(
      secureMessageId,
    );
    if (existingMessage != null) {
      print('🔴 ❌ DUPLICATE FOUND IN DB - SKIPPING');
      _logger.info(
        '📬 Duplicate message detected in repository - skipping save: ${secureMessageId.shortId()}...',
      );

      if (mounted) {
        // Check if it's in UI list - if not, add it (for chat reopen scenario)
        final inUiList = _messages.any((m) => m.id == secureMessageId);
        if (!inUiList) {
          print('🔴 Not in UI list - adding to display');
          setState(() {
            _messages.add(existingMessage);
          });
          _scrollToBottom();
        } else {
          print('🔴 Already in UI list - no action needed');
        }
      }
      return; // Skip duplicate save
    }

    print('🔴 ✅ NEW MESSAGE - PROCEEDING TO SAVE');

    final message = Message(
      id: secureMessageId, // Use secure ID, not timestamp
      chatId: _chatId,
      content: content,
      timestamp: DateTime.now(),
      isFromMe: false,
      status:
          MessageStatus.delivered, // Received messages are already delivered
    );

    // 🎯 OPTION B: Received messages go DIRECTLY to repository
    // They bypass the queue (queue is only for OUR outgoing messages)
    await _messageRepository.saveMessage(message);
    // Message saved successfully - already logged in _logMessageReceiveState above

    // 🔔 Show notification for all received messages (NotificationService handles filtering)
    try {
      _logger.info(
        '🔔 Attempting to show notification for message from $_displayContactName',
      );
      _logger.info(
        '🔔 NotificationService initialized: ${NotificationService.isInitialized}',
      );
      _logger.info(
        '🔔 Message content: ${message.content.substring(0, message.content.length > 50 ? 50 : message.content.length)}...',
      );

      await NotificationService.showMessageNotification(
        message: message,
        contactName: _displayContactName,
        contactAvatar: null,
      );

      _logger.info('✅ Notification call completed successfully');
    } catch (e, stackTrace) {
      _logger.severe('❌ Failed to show notification: $e', e, stackTrace);
    }

    if (mounted) {
      // 🔧 FIX: Check for duplicate before adding to prevent double display
      final isDuplicate = _messages.any((m) => m.id == message.id);
      if (!isDuplicate) {
        // 🔥 WhatsApp-style smart unread counting
        final shouldIncrementUnread =
            !_isUserAtBottom || _hasScrolledAwayFromBottom;

        if (shouldIncrementUnread) {
          // User is scrolled up - increment unread count
          final chatsRepo = ChatsRepository();
          await chatsRepo.incrementUnreadCount(_chatId);

          setState(() {
            _newMessagesWhileScrolledUp++;
            _unreadMessageCount++;
          });

          _logger.info(
            '📬 New message while scrolled up - unread: $_newMessagesWhileScrolledUp',
          );
        }

        setState(() {
          _messages.add(message);
          if (_showUnreadSeparator) {
            _showUnreadSeparator = false;
            _unreadSeparatorTimer?.cancel();
          }
        });

        // Only auto-scroll if user is at bottom
        if (_isUserAtBottom && !_hasScrolledAwayFromBottom) {
          _scrollToBottom();
          // Mark as read after short delay since user is watching
          _scheduleMarkAsRead();
        }
      } else {
        print('🐛 NAV DEBUG: Skipping duplicate message: ${message.id}');
      }
    }
  }

  Future<void> _processBufferedMessages() async {
    if (_messageBuffer.isEmpty) return;

    print(
      '🐛 NAV DEBUG: Processing ${_messageBuffer.length} buffered messages',
    );
    final bufferedMessages = List<String>.from(_messageBuffer);
    _messageBuffer.clear();

    for (final content in bufferedMessages) {
      await _addReceivedMessage(content);
    }
  }

  Future<void> _loadUnreadCount() async {
    if (_isRepositoryMode) {
      final chatsRepo = ChatsRepository();
      final chats = await chatsRepo.getAllChats();
      final currentChat = chats.firstWhere(
        (chat) => chat.chatId == _chatId,
        orElse: () => ChatListItem(
          chatId: '',
          contactName: '',
          contactPublicKey: null,
          lastMessage: null,
          lastMessageTime: null,
          unreadCount: 0,
          isOnline: false,
          hasUnsentMessages: false,
          lastSeen: null,
        ),
      );

      _safeSetState(() {
        _unreadMessageCount = currentChat.unreadCount;
        if (_unreadMessageCount > 0 && _messages.isNotEmpty) {
          _lastReadMessageIndex = _messages.length - _unreadMessageCount - 1;
          _showUnreadSeparator = true;
        }
      });

      // Auto-hide separator after 3 seconds
      if (_showUnreadSeparator) {
        _startUnreadSeparatorTimer();
      }
    }
  }

  void _startUnreadSeparatorTimer() {
    _unreadSeparatorTimer?.cancel();
    _unreadSeparatorTimer = Timer(Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _showUnreadSeparator = false;
        });
        _markAsRead();
      }
    });
  }

  Future<void> _markAsRead() async {
    if (_unreadMessageCount > 0 || _newMessagesWhileScrolledUp > 0) {
      final chatsRepo = ChatsRepository();
      await chatsRepo.markChatAsRead(_chatId);
      _safeSetState(() {
        _unreadMessageCount = 0;
        _lastReadMessageIndex = -1;
        _newMessagesWhileScrolledUp = 0; // 🔥 Reset new messages counter
        _hasScrolledAwayFromBottom = false; // 🔥 Reset scroll state
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final securityStateAsync = ref.watch(
      securityStateProvider(securityStateKey),
    );

    // Store successful state in cache
    securityStateAsync.whenData((state) {
      if (securityStateKey != null) {
        _securityStateCache[securityStateKey!] = state;
      }
    });

    // Use cached state if provider is loading
    securityStateAsync.when(
      data: (state) => state,
      loading: () =>
          _securityStateCache[securityStateKey ?? ''] ??
          SecurityState.disconnected(),
      error: (error, stack) => SecurityState.disconnected(),
    );

    print('🛠 DEBUG: SecurityStateProvider called for key: $securityStateKey');
    print(
      '🛠 DEBUG: SecurityState result: ${securityStateAsync.hasValue ? securityStateAsync.value.toString() : 'LOADING'}',
    );

    ref.watch(connectionInfoProvider);
    ref.watch(discoveredDevicesProvider);
    ref.watch(discoveryDataProvider);

    ref.listen(connectionInfoProvider, (previous, next) {
      _handleConnectionChange(previous?.value, next.value);
    });

    // Listen for mesh initialization status changes (moved from _monitorMeshInitialization method)
    ref.listen(meshNetworkStatusProvider, (previous, next) {
      _handleMeshInitializationStatusChange(previous, next);
    });

    // Listen for identity changes
    ref.listen(connectionInfoProvider, (previous, next) {
      if (next.hasValue &&
          next.value?.otherUserName != null &&
          next.value!.otherUserName!.isNotEmpty &&
          previous?.value?.otherUserName != next.value?.otherUserName) {
        _logger.info(
          '🔄 Identity exchange detected: ${next.value!.otherUserName}',
        );

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _handleIdentityReceived();

            Future.delayed(Duration(milliseconds: 500), () {
              if (mounted) {}
            });
          }
        });
      }
    });

    // Handle connection state changes for auto-retry
    ref.listen(connectionInfoProvider, (previous, next) {
      if (!mounted) return;

      final connectionInfo = next.maybeWhen(
        data: (info) => info,
        orElse: () => null,
      );
      if (connectionInfo == null) return;

      final isConnected = connectionInfo.isConnected;
      _logger.info('Chat screen received connection state: $isConnected');

      if (isConnected) {
        _showSuccess('Device reconnected!');
        Future.delayed(Duration(milliseconds: 2500), () {
          if (mounted) {
            _autoRetryFailedMessages();
          }
        });
      } else {
        _showError('Device disconnected');

        final bleService = ref.read(bleServiceProvider);
        if (!bleService.isPeripheralMode) {
          // 🎯 RELAY-AWARE FIX: Check if we have messages queued for relay before triggering reconnection
          if (_hasMessagesQueuedForRelay()) {
            _logger.info(
              '🔄 Not triggering reconnection - messages queued for relay via current connection',
            );
            _showInfo('Messages queued for relay - maintaining connection');
          } else {
            bleService.startConnectionMonitoring();
          }
        }
      }
    });

    try {
      final bleService = ref.watch(bleServiceProvider);
      final connectionInfoAsync = ref.watch(connectionInfoProvider);

      // Use the stabilized security state key getter
      final securityStateAsync = ref.watch(
        securityStateProvider(securityStateKey),
      );

      // Connection info for legacy compatibility
      final connectionInfo = connectionInfoAsync.maybeWhen(
        data: (info) => info,
        orElse: () => null,
      );

      final actuallyConnected = connectionInfo?.isConnected ?? false;

      return Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _isRepositoryMode
                    ? '${widget.contactName}' // 🔧 REMOVED: Redundant "Chat with" text
                    : (connectionInfo?.otherUserName ??
                          'Device $_displayContactName...'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              // Simple, clear text status
              securityStateAsync.when(
                data: (securityState) => Text(
                  _buildStatusText(connectionInfo, securityState),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: _getStatusColor(securityState),
                  ),
                ),
                loading: () => Text(
                  'Loading...',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey),
                ),
                error: (error, stack) => Text(
                  'Error',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.red),
                ),
              ),
            ],
          ),
          actions: [
            // Search button
            IconButton(
              icon: Icon(_isSearchMode ? Icons.close : Icons.search),
              onPressed: _toggleSearchMode,
              tooltip: _isSearchMode ? 'Exit search' : 'Search messages',
            ),
            // Only show relevant action button
            securityStateAsync.when(
              data: (securityState) => _buildSingleActionButton(securityState),
              loading: () => SizedBox.shrink(),
              error: (error, stack) => SizedBox.shrink(),
            ),
          ],
        ),
        body: SafeArea(
          bottom: true,
          child: Column(
            children: [
              // Reconnection banner
              if (!actuallyConnected || bleService.isActivelyReconnecting)
                _buildReconnectionBanner(),

              // Initialization status
              if (_meshInitializing) _buildInitializationStatusPanel(),

              // Search bar (when in search mode)
              if (_isSearchMode)
                ChatSearchBar(
                  messages: _messages,
                  onSearch: _onSearch,
                  onNavigateToResult: _navigateToSearchResult,
                  onExitSearch: _toggleSearchMode,
                ),

              // Messages list
              Expanded(
                child: _isLoading
                    ? Center(child: CircularProgressIndicator())
                    : _messages.isEmpty
                    ? _buildEmptyChat()
                    : ListView.builder(
                        controller: _scrollController,
                        padding: EdgeInsets.zero,
                        itemCount: _messages.length + 1,
                        itemBuilder: (context, index) {
                          if (index == _messages.length) {
                            return _buildSubtleRetryIndicator();
                          }

                          // ✅ NEW: Create the message widget
                          Widget messageWidget = MessageBubble(
                            message: _messages[index],
                            showAvatar: true,
                            showStatus: true,
                            searchQuery: _isSearchMode ? _searchQuery : null,
                            onRetry:
                                _messages[index].status == MessageStatus.failed
                                ? () => _retryMessage(_messages[index])
                                : null,
                            onDelete: (messageId, deleteForEveryone) =>
                                _deleteMessage(messageId, deleteForEveryone),
                          );

                          // ✅ NEW: Check if we need to show unread separator BEFORE this message
                          if (_showUnreadSeparator &&
                              index == _lastReadMessageIndex + 1 &&
                              _unreadMessageCount > 0) {
                            // This is the first unread message - show separator above it
                            return Column(
                              children: [
                                _buildUnreadMessageSeparator(),
                                messageWidget,
                              ],
                            );
                          }

                          // ✅ Regular message without separator
                          return messageWidget;
                        },
                      ),
              ),
              Container(
                padding: EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        decoration: InputDecoration(
                          hintText: _getMessageHintText(),
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                    SizedBox(width: 8),
                    IconButton(
                      icon: Icon(Icons.send),
                      onPressed: _sendMessage, // Always enabled
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // 🔥 Floating Action Button for scroll-to-bottom with unread count
        floatingActionButton: _shouldShowScrollDownButton()
            ? Padding(
                padding: const EdgeInsets.only(
                  bottom: 80.0,
                ), // 🔧 FIX: Add padding to lift FAB above input bar
                child: FloatingActionButton(
                  mini: true,
                  onPressed: () {
                    _scrollToBottom();
                    // Mark as read when user explicitly scrolls to bottom
                    _scheduleMarkAsRead();
                  },
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(Icons.arrow_downward),
                      if (_newMessagesWhileScrolledUp > 0)
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Container(
                            padding: EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                            constraints: BoxConstraints(
                              minWidth: 16,
                              minHeight: 16,
                            ),
                            child: Text(
                              _newMessagesWhileScrolledUp > 99
                                  ? '99+'
                                  : '$_newMessagesWhileScrolledUp',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              )
            : null,
      );
    } catch (e) {
      return Scaffold(
        appBar: AppBar(title: Text('Error')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error, size: 64, color: Colors.red),
              SizedBox(height: 16),
              Text('Error: $e'),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }
  }

  String _buildStatusText(
    ConnectionInfo? connectionInfo,
    SecurityState securityState,
  ) {
    final parts = <String>[];

    // Connection status (only for live connections)
    if (!_isRepositoryMode && connectionInfo != null) {
      if (connectionInfo.isConnected && connectionInfo.isReady) {
        parts.add('Connected');
      } else if (connectionInfo.isConnected && !connectionInfo.isReady) {
        parts.add('Connecting');
      } else if (connectionInfo.isReconnecting) {
        parts.add('Reconnecting');
      } else {
        parts.add('Offline');
      }
    }

    // Security status (always shown)
    switch (securityState.status) {
      case SecurityStatus.verifiedContact:
        parts.add('ECDH Encrypted');
        break;
      case SecurityStatus.paired:
        parts.add('Paired');
        break;
      case SecurityStatus.asymmetricContact:
        parts.add('Contact Sync Needed');
        break;
      case SecurityStatus.needsPairing:
        parts.add('Basic Encryption');
        break;
      default:
        parts.add('Disconnected');
    }

    return parts.join(' • ');
  }

  Color _getStatusColor(SecurityState securityState) {
    switch (securityState.status) {
      case SecurityStatus.verifiedContact:
        return Colors.green;
      case SecurityStatus.paired:
        return Colors.blue;
      case SecurityStatus.asymmetricContact:
        return Colors.orange;
      case SecurityStatus.needsPairing:
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  Widget _buildSingleActionButton(SecurityState securityState) {
    if (securityState.showPairingButton) {
      return IconButton(
        icon: Icon(Icons.lock_open),
        onPressed: _userRequestedPairing,
        tooltip: 'Secure Chat',
      );
    } else if (securityState.showContactAddButton) {
      return IconButton(
        icon: Icon(Icons.person_add),
        onPressed: _sendContactRequest,
        tooltip: 'Add Contact',
      );
    } else if (securityState.showContactSyncButton) {
      return IconButton(
        icon: Icon(Icons.sync),
        onPressed: () => _handleAsymmetricContact(
          securityState.otherPublicKey ?? '',
          securityState.otherUserName ?? 'Unknown',
        ),
        tooltip: 'Sync Contact',
      );
    }
    // Return empty widget instead of sized box to avoid empty space
    return SizedBox.shrink();
  }

  Widget _buildReconnectionBanner() {
    final bleService = ref.read(bleServiceProvider);

    // Check BT state for both modes first
    if (bleService.state != BluetoothLowEnergyState.poweredOn) {
      return Container(
        width: double.infinity,
        padding: EdgeInsets.all(12),
        color: Theme.of(context).colorScheme.errorContainer,
        child: Row(
          children: [
            Icon(Icons.bluetooth_disabled, size: 16),
            SizedBox(width: 8),
            Text(
              'Bluetooth is off - Please enable Bluetooth',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      );
    }

    if (_isPeripheralMode) {
      // Peripheral mode - show advertising status
      return Container(
        width: double.infinity,
        padding: EdgeInsets.all(12),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Row(
          children: [
            Icon(Icons.wifi_tethering, size: 16, color: Colors.green),
            SizedBox(width: 8),
            Text(
              'Advertising - Waiting for connection...',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      );
    } else {
      // Central mode - ONLY show banner if actively reconnecting (not health checking)
      if (bleService.isActivelyReconnecting) {
        return Container(
          width: double.infinity,
          padding: EdgeInsets.all(12),
          color: Theme.of(context).colorScheme.errorContainer,
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Searching for device...',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              TextButton(
                onPressed: _manualReconnection,
                child: Text('Reconnect Now'),
              ),
            ],
          ),
        );
      }
    }

    // No banner needed - connection is healthy
    return SizedBox.shrink();
  }

  Widget _buildUnreadMessageSeparator() {
    return Container(
      margin: EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Theme.of(context).colorScheme.primary.withValues(),
                    Theme.of(context).colorScheme.primary.withValues(),
                    Theme.of(context).colorScheme.primary.withValues(),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyChat() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          SizedBox(height: 16),
          Text(
            'Start your conversation',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Send a message to begin chatting',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubtleRetryIndicator() {
    final failedCount = _messages
        .where((m) => m.isFromMe && m.status == MessageStatus.failed)
        .length;

    if (failedCount == 0) return SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.only(top: 8, bottom: 16, left: 16, right: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          GestureDetector(
            onTap: _autoRetryFailedMessages,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary.withValues(),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 12,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant.withValues(),
                  ),
                  SizedBox(width: 4),
                  Text(
                    '$failedCount failed',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withValues(),
                    ),
                  ),
                  SizedBox(width: 6),
                  Icon(
                    Icons.refresh,
                    size: 14,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  SizedBox(width: 2),
                  Text(
                    'retry',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _sendContactRequest() async {
    setState(() => _contactRequestInProgress = true);

    final bleService = ref.read(bleServiceProvider);
    final otherPublicKey = bleService.theirPersistentKey;
    final otherName = bleService.otherUserName;

    if (otherPublicKey == null || otherName == null) {
      _showError('Cannot add contact - missing identity');
      setState(() => _contactRequestInProgress = false);
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('Add to Contacts?'),
        content: Text(
          'This will save $otherName as a trusted contact with ECDH encryption.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() => _contactRequestInProgress = false);
            },
            child: Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);

              try {
                // Don't use the complex contact request system for direct addition
                final contactRepo = ContactRepository();

                // Check if already exists
                final existingContact = await contactRepo.getContact(
                  otherPublicKey,
                );

                if (existingContact != null) {
                  print(
                    '🔧 ADD CONTACT: Already exists - just marking as verified',
                  );
                  await contactRepo.markContactVerified(otherPublicKey);

                  if (existingContact.securityLevel.index <
                      SecurityLevel.high.index) {
                    await contactRepo.updateContactSecurityLevel(
                      otherPublicKey,
                      SecurityLevel.high,
                    );
                  }
                } else {
                  print('🔧 ADD CONTACT: Creating new verified contact');
                  await contactRepo.saveContactWithSecurity(
                    otherPublicKey,
                    otherName,
                    SecurityLevel.high,
                  );
                  await contactRepo.markContactVerified(otherPublicKey);

                  // Compute ECDH if not already done
                  final sharedSecret = SimpleCrypto.computeSharedSecret(
                    otherPublicKey,
                  );
                  if (sharedSecret != null) {
                    await contactRepo.cacheSharedSecret(
                      otherPublicKey,
                      sharedSecret,
                    );
                  }
                }

                // Force refresh security state
                ref.invalidate(securityStateProvider(securityStateKey));
              } catch (e) {
                print('🔧 ADD CONTACT ERROR: $e');
              }

              setState(() => _contactRequestInProgress = false);
            },
            child: Text('Add Contact'),
          ),
        ],
      ),
    );
  }

  // Listen for incoming contact requests
  void _setupContactRequestListener() {
    final bleService = ref.read(bleServiceProvider);

    bleService.stateManager.onContactRequestCompleted = (success) {
      if (!mounted) return;
      _logger.info(
        'Contact operation completed: $success - refreshing UI state',
      );
    };

    bleService
        .stateManager
        .onContactRequestReceived = (publicKey, displayName) {
      if (!mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text('Contact Request'),
          content: Text(
            '$displayName wants to add you as a trusted contact. This enables enhanced encryption.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                bleService.stateManager.rejectContactRequest();
                Navigator.pop(context);
              },
              child: Text('Decline'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(context);
                await bleService.stateManager.acceptContactRequest();
              },
              child: Text('Accept'),
            ),
          ],
        ),
      );
    };

    // Handle asymmetric contact detection
    bleService.stateManager.onAsymmetricContactDetected =
        (publicKey, displayName) {
          if (!mounted) return;

          _logger.info('🔄 Asymmetric contact detected: $displayName');
          _handleAsymmetricContact(publicKey, displayName);
        };
  }

  void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();

    print('🔧 SEND DEBUG: Attempting to send message: "$text"');

    try {
      // Get the current contact key (ephemeral or persistent)
      final recipientKey = _contactPublicKey;

      // 📤🔑 COMPREHENSIVE SEND LOGGING (search: 📤🔑)
      await _logMessageSendState(recipientKey, text);

      print(
        '🔧 SEND DEBUG: Using AppCore.sendSecureMessage() for unified routing',
      );
      print(
        '🔧 SEND DEBUG: Recipient key: ${recipientKey != null && recipientKey.length > 16 ? "${recipientKey.shortId()}..." : recipientKey ?? "NULL"}',
      );

      // Check if we have recipient key (ephemeral or persistent)
      if (recipientKey == null || recipientKey.isEmpty) {
        print(
          '🔧 SEND DEBUG: No recipient key available (handshake may not be complete)',
        );
        _showError(
          'Connection not ready - please wait for handshake to complete',
        );
        return;
      }

      // 🔧 FIX: Get secure messageId FIRST from queue system
      // This ensures MessageRepository and OfflineMessageQueue use the SAME ID
      final secureMessageId = await AppCore.instance.sendSecureMessage(
        chatId: _chatId,
        content: text,
        recipientPublicKey: recipientKey,
      );

      // Message queued successfully - already logged in _logMessageSendState above
      print(
        '🔧 SEND DEBUG: Message queued with secure ID: ${secureMessageId.length > 16 ? '${secureMessageId.shortId()}...' : secureMessageId}',
      );

      // 🎯 OPTION B: Queue owns the message until delivery
      // Create temporary UI message to show immediately (will be replaced by queue data on reload)
      final tempMessage = Message(
        id: secureMessageId,
        chatId: _chatId,
        content: text,
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sending, // Show as sending immediately
      );

      // ✅ NO REPOSITORY SAVE! Queue will save to repository on delivery
      // Just update UI to show message immediately
      setState(() {
        _messages.add(tempMessage);
      });

      _showSuccess('✅ Message queued for delivery');
      print(
        '🔧 OPTION B: Message in queue (not saved to repository yet) - will save on delivery',
      );
      _scrollToBottom();
    } catch (e) {
      print('🔧 SEND DEBUG: Exception caught: $e');
      _logger.severe('📤🔑 MESSAGE SEND FAILED: $e');
      // 🔧 FIX: If queueing fails, show error to user
      // Don't create a failed message in repository since queue failed
      _showError('Failed to send message: $e');
    }
  }

  Future<void> _logMessageSendState(
    String? recipientKey,
    String messageContent,
  ) async {
    if (recipientKey == null) return;

    final contactRepo = ContactRepository();
    final contact = await contactRepo.getContact(recipientKey);
    final encryptionMethod = await SecurityManager.getEncryptionMethod(
      recipientKey,
      contactRepo,
    );

    final preview = messageContent.length > 30
        ? "${messageContent.shortId(30)}..."
        : messageContent;
    _logger.info(
      '📤🔑 SEND: "$preview" | To=${recipientKey.shortId()}... | Encryption=${encryptionMethod.type.name} | NoiseSession=${contact?.sessionIdForNoise?.shortId() ?? "NULL"}...',
    );
  }

  Future<void> _logMessageReceiveState(
    String? senderKey,
    String messageContent,
    String messageId,
  ) async {
    if (senderKey == null) return;

    final contactRepo = ContactRepository();
    final contact = await contactRepo.getContact(senderKey);
    final encryptionMethod = await SecurityManager.getEncryptionMethod(
      senderKey,
      contactRepo,
    );

    final preview = messageContent.length > 30
        ? "${messageContent.shortId(30)}..."
        : messageContent;
    _logger.info(
      '📥🔑 RECV: "$preview" | From=${senderKey.shortId()}... | MsgID=${messageId.shortId()}... | Encryption=${encryptionMethod.type.name} | NoiseSession=${contact?.sessionIdForNoise?.shortId() ?? "NULL"}...',
    );
  }

  Future<void> _retryMessage(Message failedMessage) async {
    final bleService = ref.read(bleServiceProvider);

    final connectionInfo = ref.read(connectionInfoProvider).value;
    if (!(connectionInfo?.isConnected ?? false)) {
      _showError('Not connected. Please reconnect to the device first.');
      return;
    }

    _showSuccess('Retrying message...');

    // Update to sending status
    final retryMessage = failedMessage.copyWith(status: MessageStatus.sending);
    await _messageRepository.updateMessage(retryMessage);
    setState(() {
      final index = _messages.indexWhere((m) => m.id == failedMessage.id);
      if (index != -1) {
        _messages[index] = retryMessage;
      }
    });

    // Retry sending
    try {
      final success = await bleService.sendMessage(
        failedMessage.content,
        messageId: failedMessage.id,
      );

      final newStatus = success
          ? MessageStatus.delivered
          : MessageStatus.failed;
      final updatedMessage = retryMessage.copyWith(status: newStatus);
      await _messageRepository.updateMessage(updatedMessage);
      setState(() {
        final index = _messages.indexWhere((m) => m.id == failedMessage.id);
        if (index != -1) {
          _messages[index] = updatedMessage;
        }
      });

      if (success) {
        _showSuccess('Message delivered!');
      } else {
        _showError('Retry failed - message timeout');
      }
    } catch (e) {
      final failedAgain = retryMessage.copyWith(status: MessageStatus.failed);
      await _messageRepository.updateMessage(failedAgain);
      setState(() {
        final index = _messages.indexWhere((m) => m.id == failedMessage.id);
        if (index != -1) {
          _messages[index] = failedAgain;
        }
      });
      _showError('Retry failed: ${e.toString().split(':').last}');
    }
  }

  Future<void> _deleteMessage(String messageId, bool deleteForEveryone) async {
    try {
      // Delete from local repository
      final success = await _messageRepository.deleteMessage(messageId);

      if (success) {
        // Remove from UI immediately (optimistic update)
        setState(() {
          _messages.removeWhere((message) => message.id == messageId);
        });

        // If deleteForEveryone is true, send deletion request (using MessageRouter for offline reliability)
        if (deleteForEveryone) {
          try {
            // Send deletion request using MessageRouter (BitChat pattern)
            // MessageRouter will queue if peer offline and auto-send when online
            final deletionMessage = 'DELETE_MESSAGE:$messageId';
            final router = MessageRouter.instance;

            final result = await router.sendMessage(
              content: deletionMessage,
              recipientId: _contactPublicKey ?? _chatId,
              recipientName: _displayContactName,
            );

            if (result.isSentDirectly) {
              _showSuccess('Message deleted for everyone');
            } else if (result.isQueued) {
              _showSuccess(
                'Message deleted - deletion request queued (will send when peer online)',
              );
            } else {
              _showSuccess('Message deleted locally (remote deletion queued)');
            }
          } catch (e) {
            _logger.warning('Failed to send deletion request: $e');
            _showSuccess('Message deleted locally (remote deletion failed)');
          }
        } else {
          _showSuccess('Message deleted');
        }
      } else {
        _showError('Failed to delete message');
      }
    } catch (e) {
      _logger.severe('Error deleting message: $e');
      _showError('Failed to delete message: $e');
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && mounted) {
        Future.delayed(Duration(milliseconds: 50), () {
          if (_scrollController.hasClients && mounted) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        });
      }
    });
  }

  String _getMessageHintText() {
    if (_isRepositoryMode) {
      return 'Type a message...';
    }

    final connectionInfo = ref.read(connectionInfoProvider).value;
    if (connectionInfo?.isConnected != true) {
      return 'Message will send when connected...';
    }

    if (connectionInfo?.isReady != true) {
      return 'Connecting... message will send when ready...';
    }

    return 'Type a message...';
  }

  String _calculateInitialChatId() {
    // Repository mode: use provided chatId
    if (_isRepositoryMode) {
      return widget.chatId!;
    }

    // Live connection mode: generate from BLE service
    final bleService = ref.read(bleServiceProvider);
    final otherPersistentId = bleService.currentSessionId;

    if (otherPersistentId != null) {
      return ChatUtils.generateChatId(otherPersistentId);
    }

    // Fallback for live connections
    final deviceId = _isCentralMode
        ? widget.device!.uuid.toString()
        : widget.central!.uuid.toString();

    return 'temp_${deviceId.shortId(8)}';
  }

  Future<void> _handleIdentityReceived() async {
    final bleService = ref.read(bleServiceProvider);
    final otherPersistentId = bleService.theirPersistentKey;

    // Note: No need to cache the persistent key anymore - we reactively read it
    // via _contactPublicKey getter which gets it from bleService.currentSessionId

    if (otherPersistentId != null) {
      final newChatId = ChatUtils.generateChatId(otherPersistentId);

      if (newChatId != _currentChatId) {
        final messagesToMigrate = await _messageRepository.getMessages(
          _currentChatId!,
        );

        if (messagesToMigrate.isNotEmpty) {
          _logger.info(
            'Identity received - migrating ${messagesToMigrate.length} messages from $_currentChatId to $newChatId',
          );
          await _migrateMessages(_currentChatId!, newChatId);
          _currentChatId = newChatId;
          await _loadMessages();
        } else {
          _logger.info(
            'Identity received - switching to persistent chat ID but no messages to migrate',
          );
          _currentChatId = newChatId;
        }

        // IMPORTANT: Don't invalidate security state here - it should persist
      }
    }
  }

  Future<void> _migrateMessages(String oldChatId, String newChatId) async {
    final oldMessages = await _messageRepository.getMessages(oldChatId);

    for (final message in oldMessages) {
      final migratedMessage = Message(
        id: message.id,
        chatId: newChatId, // NEW chat ID
        content: message.content,
        timestamp: message.timestamp,
        isFromMe: message.isFromMe,
        status: message.status,
      );
      await _messageRepository.saveMessage(migratedMessage);
    }

    // Clean up old temp messages
    await _messageRepository.clearMessages(oldChatId);
    _logger.info(
      'Migrated ${oldMessages.length} messages from $oldChatId to $newChatId',
    );
  }

  void _handleConnectionChange(
    ConnectionInfo? previous,
    ConnectionInfo? current,
  ) {
    if (!mounted) return;

    // Only react to meaningful changes
    final wasConnected = previous?.isConnected ?? false;
    final isConnected = current?.isConnected ?? false;
    final wasReady = previous?.isReady ?? false;
    final isReady = current?.isReady ?? false;

    if (!wasConnected && isConnected) {
      _showSuccess('Connected to device!');
    } else if (wasConnected && !isConnected) {
      _showError('Device disconnected');
    } else if (isConnected && !wasReady && isReady) {
      _showSuccess('Identity exchange complete!');
      // Trigger auto-retry after identity is established
      Future.delayed(Duration(milliseconds: 1000), () {
        if (mounted) _autoRetryFailedMessages();
      });
    }
  }

  void _showError(String message) {
    _logger.warning('Error: $message');
  }

  void _showInfo(String message) {
    _logger.info('Info: $message');
  }

  void _showSuccess(String message) {
    _logger.info('Success: $message');
  }

  /// Handle mesh demo events for UI feedback
  void _handleMeshDemoEvent(DemoEvent event) {
    // This is a simplified handler since we can't access private classes
    final eventString = event.toString();

    if (eventString.contains('MessageDelivered')) {
      _showSuccess('✅ Mesh message delivered!');
    } else if (eventString.contains('MessageFailed')) {
      _showError('❌ Mesh delivery failed');
    } else if (eventString.contains('MessageRelayed')) {
      _showSuccess('🔀 Message relayed through mesh');
    } else if (eventString.contains('RelayDecisionMade')) {
      _showSuccess('🤔 Relay decision processed');
    }
  }

  /// Toggle search mode
  void _toggleSearchMode() {
    setState(() {
      if (_isSearchMode) {
        // Exit search mode
        _isSearchMode = false;
        _searchQuery = '';
      } else {
        // Enter search mode
        _isSearchMode = true;
      }
    });

    _logger.info('Search mode toggled: $_isSearchMode');
  }

  /// Handle search query changes
  void _onSearch(String query, List<SearchResult> results) {
    setState(() {
      _searchQuery = query;
      // Search results are handled by the search widget directly
    });
  }

  /// Navigate to a specific search result
  void _navigateToSearchResult(int messageIndex) {
    if (messageIndex >= 0 && messageIndex < _messages.length) {
      _scrollController.animateTo(
        // Calculate approximate position - this is a simple estimation
        messageIndex * 120.0, // Rough estimate of message height
        duration: Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  /// Build initialization status panel
  Widget _buildInitializationStatusPanel() {
    return Container(
      padding: EdgeInsets.all(12),
      margin: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Smart Routing Mesh Network',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
                Text(
                  _initializationStatus,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                ),
              ],
            ),
          ),
          // 🔧 REMOVED: FYP Demo label for cleaner UX
        ],
      ),
    );
  }

  @override
  void dispose() {
    print('🐛 NAV DEBUG: ChatScreen dispose() called');
    // 🔧 FIX: Use cached value instead of getter to avoid ref.read() during dispose
    final cachedKey = _cachedContactPublicKey;
    print(
      '🐛 NAV DEBUG: - Final contact key: ${cachedKey != null && cachedKey.length > 16 ? '${cachedKey.shortId()}...' : cachedKey ?? 'null'}',
    );
    print('🐛 NAV DEBUG: - Final chatId: $_currentChatId');
    print('🐛 NAV DEBUG: - Message listener active: $_messageListenerActive');
    print('🐛 NAV DEBUG: - Buffered messages: ${_messageBuffer.length}');
    print(
      '🐛 NAV DEBUG: - Persistent manager buffered: ${_persistentChatManager?.getBufferedMessageCount(_chatId) ?? 0}',
    );

    // Unregister from persistent manager (but keep listener active for buffering)
    if (_persistentChatManager != null) {
      _persistentChatManager!.unregisterChatScreen(_chatId);
      print('🐛 NAV DEBUG: Unregistered from PersistentChatStateManager');
    }

    // Deactivate listener but don't cancel subscription to allow message buffering
    _messageListenerActive = false;

    // Only cancel direct subscriptions (persistent manager handles its own)
    if (_messageSubscription != null) {
      _messageSubscription!.cancel();
      _messageSubscription = null;
    }

    _meshEventSubscription?.cancel();
    _deliverySubscription?.cancel();
    _initializationTimeoutTimer?.cancel();

    // 🔥 Clean up smart unread timers
    _markAsReadDebounceTimer?.cancel();
    _scrollController.removeListener(
      _onScroll,
    ); // Remove scroll listener before disposing

    _messageController.dispose();
    _scrollController.dispose();
    _unreadSeparatorTimer?.cancel();

    super.dispose();

    print(
      '🐛 NAV DEBUG: ChatScreen dispose() completed - persistent listener maintained',
    );
  }
}
