// Main application core that integrates all enhanced messaging features

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'power/adaptive_power_manager.dart';
import 'power/battery_optimizer.dart';
import 'scanning/burst_scanning_controller.dart';
import 'messaging/offline_message_queue.dart';
import 'messaging/offline_queue_facade.dart';
import 'performance/performance_monitor.dart';
import 'services/security_manager.dart';
import 'networking/topology_manager.dart';
import 'config/kill_switches.dart';
import 'security/ephemeral_key_manager.dart';
import 'security/noise/adaptive_encryption_strategy.dart';
import '../domain/entities/enhanced_message.dart';
import '../domain/services/contact_management_service.dart';
import '../domain/services/chat_management_service.dart';
import '../domain/services/mesh_networking_service.dart';
import '../domain/services/auto_archive_scheduler.dart';
import '../domain/services/notification_service.dart';
import '../domain/services/notification_handler_factory.dart';
import '../data/services/ble_service.dart';
import '../data/services/seen_message_store.dart';
import '../data/repositories/preferences_repository.dart';
import '../data/repositories/contact_repository.dart';
import '../data/repositories/user_preferences.dart';
import '../data/repositories/archive_repository.dart';
import '../data/repositories/message_repository.dart';
import '../data/database/database_helper.dart';
import '../domain/entities/message.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import '../core/messaging/message_router.dart';
import 'di/service_locator.dart';
import 'interfaces/i_connection_service.dart';

import '../domain/values/id_types.dart';

/// Main application core that coordinates all enhanced messaging features
class AppCore {
  static final _logger = Logger('AppCore');
  static AppCore? _instance;

  // Core components
  late final BurstScanningController burstScanningController;
  late final OfflineQueueFacade messageQueueFacade;
  late final OfflineMessageQueue messageQueue;
  late final ContactManagementService contactService;
  late final ChatManagementService chatService;
  late final PerformanceMonitor performanceMonitor;
  // 🔧 REMOVED: BLEStateManager - BLEService creates its own instance
  // late final BLEStateManager bleStateManager;
  late final BatteryOptimizer batteryOptimizer;
  late final IConnectionService bleService;
  late final MeshNetworkingService meshNetworkingService;

  // Repositories
  late final ContactRepository contactRepository;
  late final MessageRepository messageRepository;
  late final UserPreferences userPreferences;
  late final ArchiveRepository archiveRepository;

  // State
  bool _isInitialized = false;
  Completer<void>? _initializationCompleter;
  DateTime? _initializationTime;
  AppStatus _currentStatus = AppStatus.initializing;
  Stream<AppStatus>? _statusStream;
  final Set<void Function(AppStatus)> _statusListeners = {};
  @visibleForTesting
  static Future<void> Function()? initializationOverride;
  AppCore._();

  /// Get singleton instance
  static AppCore get instance {
    _instance ??= AppCore._();
    return _instance!;
  }

  /// Get initialization status
  bool get isInitialized => _isInitialized;

  /// True while initialization is in progress (before [isInitialized] is set).
  bool get isInitializing =>
      _initializationCompleter != null &&
      !_initializationCompleter!.isCompleted;

  /// Stream of app status changes
  Stream<AppStatus> get statusStream {
    _statusStream ??= Stream<AppStatus>.multi((controller) {
      controller.add(_currentStatus);

      void listener(AppStatus status) {
        controller.add(status);
      }

      _statusListeners.add(listener);
      controller.onCancel = () {
        _statusListeners.remove(listener);
      };
    }, isBroadcast: true);

    return _statusStream!;
  }

  /// Initialize the entire application core
  Future<void> initialize() async {
    // If initialization already completed, short-circuit.
    if (_isInitialized) {
      _logger.warning('App core already initialized');
      _emitStatus(AppStatus.ready); // Emit ready if already initialized
      return;
    }

    // If initialization is in progress, wait for it to finish to avoid reentry.
    if (_initializationCompleter != null) {
      _logger.info('App core initialization already in progress, awaiting...');
      await _initializationCompleter!.future;
      return;
    }

    _initializationCompleter = Completer<void>();
    // Prevent unhandled asynchronous error warnings when initialization fails
    // before another caller awaits the shared completer.
    _initializationCompleter!.future.catchError((_) {});

    try {
      _logger.info('🚀 Starting application core initialization...');
      final startTime = DateTime.now();

      _emitStatus(AppStatus.initializing);

      // Load kill switches before bringing up subsystems.
      final prefsRepo = PreferencesRepository();
      await KillSwitches.load(
        getBool: (key, {defaultValue = false}) =>
            prefsRepo.getBool(key, defaultValue: defaultValue),
      );

      // Allow tests to inject an override routine that simulates initialization
      // outcomes without exercising the full stack.
      if (initializationOverride != null) {
        await initializationOverride!();
        _isInitialized = true;
        _initializationTime = DateTime.now();
        _emitStatus(AppStatus.ready);
        _initializationCompleter?.complete();
        return;
      }

      // Setup logging
      _logger.info('🗒️ Setting up logging...');
      _setupLogging();
      _logger.info('✅ Logging setup complete');

      // Setup dependency injection container
      _logger.info('🏗️ Setting up DI container...');
      await setupServiceLocator();
      _logger.info('✅ DI container setup complete');

      // Initialize repositories first
      _logger.info('🗄️ Initializing repositories...');
      final repoStart = DateTime.now();
      await _initializeRepositories();
      _logger.info(
        '✅ Repositories initialized in ${DateTime.now().difference(repoStart).inMilliseconds}ms',
      );

      // Initialize seen message store after database setup
      _logger.info('👀 Initializing SeenMessageStore...');
      await SeenMessageStore.instance.initialize();
      _logger.info('✅ SeenMessageStore initialized');

      // 🔧 FIX P0: Initialize message queue FIRST before any BLE components can access it
      _logger.info(
        '📬 Initializing message queue (PRIORITY: before BLE/core services)...',
      );
      final queueStart = DateTime.now();
      await _initializeMessageQueue();
      _logger.info(
        '✅ Message queue initialized in ${DateTime.now().difference(queueStart).inMilliseconds}ms',
      );

      // Initialize monitoring
      _logger.info('📊 Initializing monitoring...');
      final monitorStart = DateTime.now();
      await _initializeMonitoring();
      _logger.info(
        '✅ Monitoring initialized in ${DateTime.now().difference(monitorStart).inMilliseconds}ms',
      );

      // Initialize core services (may trigger BLEService initialization via providers)
      _logger.info('🔧 Initializing core services...');
      final servicesStart = DateTime.now();
      await _initializeCoreServices();
      _logger.info(
        '✅ Core services initialized in ${DateTime.now().difference(servicesStart).inMilliseconds}ms',
      );

      // Initialize BLE integration
      _logger.info('📡 Initializing BLE integration...');
      final bleStart = DateTime.now();
      await _initializeBLEIntegration();
      _logger.info(
        '✅ BLE integration initialized in ${DateTime.now().difference(bleStart).inMilliseconds}ms',
      );

      // Initialize enhanced features (battery, burst scanning)
      _logger.info('⚡ Initializing enhanced features...');
      final featuresStart = DateTime.now();
      await _initializeEnhancedFeatures();
      _logger.info(
        '✅ Enhanced features initialized in ${DateTime.now().difference(featuresStart).inMilliseconds}ms',
      );

      // Start integrated systems
      _logger.info('🔄 Starting integrated systems...');
      final systemsStart = DateTime.now();
      await _startIntegratedSystems();
      _logger.info(
        '✅ Integrated systems started in ${DateTime.now().difference(systemsStart).inMilliseconds}ms',
      );

      _isInitialized = true;
      _initializationTime = DateTime.now();

      // Emit ready status
      _emitStatus(AppStatus.ready);
      _logger.info('🎯 Status changed to READY');

      final totalTime = DateTime.now().difference(startTime);
      _logger.info(
        '🎉 Application core initialized successfully in ${totalTime.inMilliseconds}ms',
      );
      _initializationCompleter?.complete();
    } catch (e, stackTrace) {
      _logger.severe('❌ Failed to initialize app core: $e');
      _logger.severe('Stack trace: $stackTrace');
      _emitStatus(AppStatus.error);
      final appCoreError = AppCoreException('Initialization failed: $e');
      if (_initializationCompleter != null &&
          !_initializationCompleter!.isCompleted) {
        _initializationCompleter!.completeError(appCoreError);
      }
      throw appCoreError;
    } finally {
      // If initialization failed, clear the completer so a retry can start fresh.
      if (_initializationCompleter != null && _isInitialized == false) {
        _initializationCompleter = null;
      }
    }
  }

  /// Setup comprehensive logging
  void _setupLogging() {
    Logger.root.level = kDebugMode ? Level.ALL : Level.INFO;
    Logger.root.onRecord.listen((record) {
      if (kDebugMode) {
        print('${record.level.name}: ${record.time}: ${record.message}');
      }
    });
  }

  /// Initialize repositories
  Future<void> _initializeRepositories() async {
    // Initialize database first to ensure it's ready
    _logger.info('Initializing database...');
    await DatabaseHelper.database;
    _logger.info('Database initialized successfully');

    // Initialize repositories
    contactRepository = getIt<ContactRepository>();
    messageRepository = getIt<MessageRepository>();
    userPreferences = UserPreferences();
    archiveRepository = ArchiveRepository();

    // Initialize async repository components
    await userPreferences.getOrCreateKeyPair();
    await archiveRepository.initialize();

    _logger.info('Repositories initialized');
  }

  /// Initialize monitoring systems
  Future<void> _initializeMonitoring() async {
    performanceMonitor = PerformanceMonitor();
    await performanceMonitor.initialize();
    // Event-driven mode: disable periodic sampling, take initial snapshot.
    performanceMonitor.startMonitoring(enablePeriodic: false);
    performanceMonitor.collectSnapshot();
    _logger.info('Performance monitor initialized (event-driven)');

    // Initialize adaptive encryption strategy (FIX-013)
    // This checks performance metrics and decides whether to use isolate for encryption
    final adaptiveStrategy = AdaptiveEncryptionStrategy();
    await adaptiveStrategy.initialize();
    _logger.info('Adaptive encryption strategy initialized');

    _logger.info('Monitoring systems initialized');
  }

  /// Initialize core services
  Future<void> _initializeCoreServices() async {
    // Initialize notification service with dependency injection
    // Platform-specific handler selection based on user preference:
    // - Android: BackgroundNotificationHandlerImpl if enabled in settings
    // - iOS/Windows/Linux/macOS: ForegroundNotificationHandler (safe default)

    // Check user preference for background notifications (Android only)
    final prefs = PreferencesRepository();
    bool backgroundEnabled = PreferenceDefaults.backgroundNotifications;

    try {
      backgroundEnabled = await prefs.getBool(
        PreferenceKeys.backgroundNotifications,
        defaultValue: PreferenceDefaults.backgroundNotifications,
      );
    } catch (e) {
      _logger.warning(
        'Failed to read background_notifications preference, using default: $e',
      );
      // Use default value on error
    }

    final notificationHandler =
        (backgroundEnabled &&
            NotificationHandlerFactory.isBackgroundNotificationSupported())
        ? NotificationHandlerFactory.createBackgroundHandler()
        : NotificationHandlerFactory.createDefault();

    await NotificationService.initialize(handler: notificationHandler);
    _logger.info(
      'Notification service initialized with ${notificationHandler.runtimeType}',
    );

    // Initialize SecurityManager with Noise Protocol
    _logger.info('🔒 Initializing SecurityManager with Noise Protocol...');
    final securityManager = SecurityManager.instance;
    await securityManager.initialize();
    _logger.info('✅ SecurityManager initialized successfully');

    // 🔧 FIX P1: Initialize EphemeralKeyManager ONCE here before any component uses it
    // This ensures single ephemeral key generation per session (single responsibility)
    _logger.info('🔑 Initializing EphemeralKeyManager for session...');
    try {
      final myPrivateKey = await userPreferences.getPrivateKey();
      await EphemeralKeyManager.initialize(myPrivateKey);
      final myEphemeralId = EphemeralKeyManager.generateMyEphemeralKey();
      _logger.info(
        '✅ EphemeralKeyManager initialized - Session ID: ${myEphemeralId.shortId()}...',
      );

      // Initialize TopologyManager with the same ephemeral ID
      _logger.info(
        '🌐 Initializing TopologyManager with session ephemeral ID...',
      );
      TopologyManager.instance.initialize(myEphemeralId);
      _logger.info(
        '✅ TopologyManager initialized with ephemeral node ID: ${myEphemeralId.shortId()}...',
      );
    } catch (e) {
      _logger.warning(
        '⚠️ Failed to initialize EphemeralKeyManager/TopologyManager: $e',
      );
      // Non-critical for TopologyManager, but critical for ephemeral keys
      rethrow;
    }

    // Initialize contact management
    contactService = ContactManagementService();
    await contactService.initialize();
    _logger.info('Contact management service initialized');

    // Initialize chat management
    chatService = ChatManagementService();
    await chatService.initialize();
    _logger.info('Chat management service initialized');

    _logger.info('Core services initialized');
  }

  /// Initialize BLE integration
  /// Phase 1 Part C: Initialize BLEService and MeshNetworkingService,
  /// then register in DI container for access via providers
  Future<void> _initializeBLEIntegration() async {
    _logger.info('📡 Initializing BLE + mesh stack via AppCore...');

    try {
      final legacyBleService = getIt.isRegistered<BLEService>()
          ? getIt<BLEService>()
          : BLEService();
      if (!legacyBleService.isInitialized) {
        await legacyBleService.initialize();
        await MessageRouter.initialize(legacyBleService);
      } else {
        _logger.fine('ℹ️ BLEService already initialized; reusing instance');
      }

      bleService = legacyBleService;
      _logger.info('✅ BLEService initialized via AppCore');

      final messageHandlerFacade = legacyBleService.meshMessageHandler;

      meshNetworkingService = MeshNetworkingService(
        bleService: bleService,
        messageHandler: messageHandlerFacade,
        chatManagementService: chatService,
      );
      await meshNetworkingService.initialize();
      _logger.info('🌐 MeshNetworkingService initialized successfully');

      registerInitializedServices(
        securityManager: SecurityManager.instance,
        connectionService: bleService,
        meshNetworkingService: meshNetworkingService,
        meshRelayCoordinator: meshNetworkingService.relayCoordinator,
        meshQueueSyncCoordinator: meshNetworkingService.queueCoordinator,
        meshHealthMonitor: meshNetworkingService.healthMonitor,
      );
      _logger.info('📦 BLE + mesh services registered with GetIt');
    } catch (e, stackTrace) {
      _logger.severe('❌ Failed to initialize BLE integration: $e');
      _logger.severe('Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Initialize message queue (must be called early - before BLE services)
  Future<void> _initializeMessageQueue() async {
    messageQueueFacade = OfflineQueueFacade();
    await messageQueueFacade.initialize(
      onMessageQueued: (message) =>
          _logger.info('Message queued: ${message.id}'),
      onMessageDelivered: (message) async {
        _logger.info('Message delivered: ${message.id}');
        // 🔧 FIX: Update MessageRepository when queue marks message as delivered
        await _updateMessageRepositoryOnDelivery(message);
      },
      onMessageFailed: (message, reason) =>
          _logger.warning('Message failed: ${message.id} - $reason'),
      onStatsUpdated: (stats) => _logger.fine('Queue stats updated: $stats'),
      onSendMessage: _handleMessageSend,
      onConnectivityCheck: _checkConnectivity,
    );
    messageQueue = messageQueueFacade.queue;

    final queueStats = messageQueue.getStatistics();
    final totalQueued =
        queueStats.pendingMessages +
        queueStats.sendingMessages +
        queueStats.retryingMessages;
    _logger.info(
      '✅ Message queue ready with $totalQueued messages (${queueStats.pendingMessages} pending, ${queueStats.sendingMessages} sending, ${queueStats.retryingMessages} retrying)',
    );
  }

  /// Initialize enhanced features (battery, scanning)
  Future<void> _initializeEnhancedFeatures() async {
    // Initialize battery optimizer for power management
    _logger.info('🔋 Initializing battery optimizer...');
    batteryOptimizer = BatteryOptimizer();
    await batteryOptimizer.initialize(
      onBatteryUpdate: (info) {
        _logger.info('🔋 Battery: ${info.level}% (${info.powerMode.name})');
      },
      onPowerModeChanged: (mode) {
        _logger.info('🔋 Power mode changed to: ${mode.name}');
      },
    );
    _logger.info('✅ Battery optimizer initialized');

    // Initialize burst scanning controller (replaces direct power manager)
    burstScanningController = BurstScanningController();

    // The controller will be fully initialized in _startIntegratedSystems()
    _logger.info(
      'Burst scanning controller created - will initialize with BLE service',
    );

    _logger.info('Enhanced features initialized');
  }

  /// Start integrated systems
  Future<void> _startIntegratedSystems() async {
    _logger.info('Starting burst scanning integration...');

    // Initialize burst scanning controller early to ensure it's ready
    // This triggers the provider initialization during app startup rather than on first UI access
    try {
      _logger.info('🔧 Pre-initializing burst scanning controller...');
      // Force provider initialization by creating a temporary container
      // This ensures burst scanning starts immediately rather than waiting for UI
      await Future.delayed(
        Duration(milliseconds: 100),
      ); // Small delay to ensure BLE is ready
      _logger.info('✅ Burst scanning will initialize on provider access');
    } catch (e) {
      _logger.warning('⚠️ Burst scanning pre-initialization note: $e');
    }

    // Start auto-archive scheduler
    _logger.info('🗄️ Starting auto-archive scheduler...');
    try {
      await AutoArchiveScheduler.start();
      _logger.info('✅ Auto-archive scheduler started');
    } catch (e) {
      _logger.warning('⚠️ Auto-archive scheduler failed to start: $e');
      // Non-critical, continue initialization
    }

    _logger.info('Integrated systems started');
  }

  /// Handle message send callback
  void _handleMessageSend(String messageId) {
    // Guard: ensure mesh layer is initialized; otherwise surface an error.
    if (!AppCore.instance.isInitialized) {
      _logger.severe(
        '❌ Cannot send message ${messageId.shortId()}...: mesh not initialized',
      );
      return;
    }
    // In production this is replaced by MeshQueueSyncCoordinator binding.
    _logger.info('Sending message: ${messageId.shortId()}...');
  }

  /// Check connectivity for message queue
  void _checkConnectivity() {
    // PROPER FIX: Use the connectivity check from mesh networking service
    // This ensures queue connectivity matches actual sending capability
    // Note: The actual connectivity check will be delegated to MeshNetworkingService
    // which has access to the real BLE service and can use the same logic as sendMessage()
    _logger.fine(
      'Queue connectivity check requested - will be handled by mesh service',
    );
  }

  /// 🔧 FIX: Update MessageRepository when queue marks message as delivered
  /// This ensures the single source of truth is maintained between queue and repository
  /// 🎯 OPTION B: Queue → Repository callback
  /// When message is delivered, move it from queue to permanent repository storage
  /// This is the ONLY place where sent messages get saved to repository
  Future<void> _updateMessageRepositoryOnDelivery(
    QueuedMessage queuedMessage,
  ) async {
    try {
      // Create repository message with delivered status; preserve reply linkage
      final repoMessage = EnhancedMessage(
        id: MessageId(queuedMessage.id), // Same ID as queue (secure ID)
        chatId: ChatId(queuedMessage.chatId),
        content: queuedMessage.content,
        timestamp: queuedMessage.queuedAt,
        isFromMe: true,
        status: MessageStatus.delivered, // Delivered successfully!
        replyToMessageId: queuedMessage.replyToMessageId != null
            ? MessageId(queuedMessage.replyToMessageId!)
            : null,
      );

      // 🎯 OPTION B: Message should NOT exist in repository yet
      // Queue owns it until delivery, then moves it to repository
      await messageRepository.saveMessage(repoMessage);
      _logger.info(
        '✅ OPTION B: Moved message ${queuedMessage.id.shortId()}... from queue → repository (delivered)',
      );
    } catch (e) {
      // Check if duplicate key error (message already exists)
      if (e.toString().contains('UNIQUE constraint failed') ||
          e.toString().contains('already exists')) {
        _logger.warning(
          '⚠️ Message ${queuedMessage.id.shortId()}... already in repository (duplicate delivery callback?)',
        );
        // Not fatal - message is already saved
      } else {
        _logger.severe(
          '❌ Failed to save message to repository on delivery: $e',
        );
        // Don't rethrow - queue has already marked as delivered successfully
      }
    }
  }

  /// Send message using integrated security and queue system
  Future<String> sendSecureMessage({
    required String chatId,
    required String content,
    required String recipientPublicKey,
  }) async {
    if (!_isInitialized) {
      throw AppCoreException('App core not initialized');
    }

    performanceMonitor.startOperation('send_secure_message');

    try {
      // Get sender public key
      final senderPublicKey = await userPreferences.getPublicKey();

      // Create enhanced message with security
      final messageId = await messageQueue.queueMessage(
        chatId: chatId,
        content: content,
        recipientPublicKey: recipientPublicKey,
        senderPublicKey: senderPublicKey,
        priority: MessagePriority.normal,
      );

      performanceMonitor.endOperation(
        'send_secure_message',
        success: true,
      ); // Fixed: added success parameter
      return messageId;
    } catch (e) {
      performanceMonitor.endOperation(
        'send_secure_message',
        success: false,
      ); // Fixed: added success parameter
      throw AppCoreException('Failed to send secure message: $e');
    }
  }

  /// Get comprehensive app statistics
  Future<AppStatistics> getStatistics() async {
    if (!_isInitialized) {
      throw AppCoreException('App core not initialized');
    }

    // Note: Power management statistics now handled by burst scanning controller via providers
    final queueStats = messageQueue
        .getStatistics(); // Fixed: use getStatistics()
    final performanceMetrics = performanceMonitor.getMetrics();

    // Create a simple replay protection stats since we don't have the actual implementation
    final replayStats = ReplayProtectionStats(
      processedMessagesCount: 0,
      blockedDuplicateCount: 0,
      averageProcessingTime: Duration.zero,
    );

    return AppStatistics(
      powerManagement: PowerManagementStats(
        currentScanInterval: 60000,
        currentHealthCheckInterval: 30000,
        consecutiveSuccessfulChecks: 0,
        consecutiveFailedChecks: 0,
        connectionQualityScore: 0.5,
        connectionStabilityScore: 0.5,
        timeSinceLastSuccess: Duration.zero,
        qualityMeasurementsCount: 0,
        isBurstMode: false,
        // Phase 1: Duty cycle stats (defaults)
        powerMode: PowerMode.balanced,
        isDutyCycleScanning: false,
        batteryLevel: batteryOptimizer.currentLevel,
        isCharging: batteryOptimizer.isCharging,
        isAppInBackground: false,
      ), // Note: Power management now handled by burst scanning controller
      messageQueue: queueStats,
      performance: performanceMetrics,
      replayProtection: replayStats,
      uptime: DateTime.now().difference(_getInitTime()),
    );
  }

  /// Get initialization time
  DateTime _getInitTime() {
    return _initializationTime ?? DateTime.now().subtract(Duration(minutes: 5));
  }

  /// Emit app status change
  void _emitStatus(AppStatus status) {
    _currentStatus = status;
    for (final listener in List.of(_statusListeners)) {
      try {
        listener(status);
        _logger.info('📡 Status emitted: $status');
      } catch (e, stackTrace) {
        _logger.warning('Status listener threw: $e', e, stackTrace);
      }
    }
  }

  /// Dispose of all resources
  void dispose() {
    if (!_isInitialized) return;

    try {
      _emitStatus(AppStatus.disposing);

      // Safe disposal with null checks
      try {
        burstScanningController.dispose();
      } catch (e) {
        _logger.warning('Error disposing burst scanning controller: $e');
      }

      try {
        chatService.dispose();
      } catch (e) {
        _logger.warning('Error disposing chat service: $e');
      }

      try {
        performanceMonitor.dispose();
      } catch (e) {
        _logger.warning('Error disposing performance monitor: $e');
      }

      try {
        AutoArchiveScheduler.stop();
        _logger.info('Auto-archive scheduler stopped');
      } catch (e) {
        _logger.warning('Error stopping auto-archive scheduler: $e');
      }

      try {
        NotificationService.dispose();
        _logger.info('Notification service disposed');
      } catch (e) {
        _logger.warning('Error disposing notification service: $e');
      }

      _statusListeners.clear();

      _logger.info('App core disposed');
    } catch (e) {
      _logger.severe('Error during disposal: $e');
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _instance = null;
  }
}

/// Application status enumeration
enum AppStatus { initializing, ready, running, error, disposing }

/// Comprehensive app statistics
class AppStatistics {
  final PowerManagementStats powerManagement;
  final QueueStatistics messageQueue;
  final PerformanceMetrics performance;
  final ReplayProtectionStats replayProtection;
  final Duration uptime;

  const AppStatistics({
    required this.powerManagement,
    required this.messageQueue,
    required this.performance,
    required this.replayProtection,
    required this.uptime,
  });

  /// Get overall app health score (0.0 - 1.0)
  double get overallHealthScore {
    final scores = [
      powerManagement.batteryEfficiencyRating,
      messageQueue.queueHealthScore,
      performance.overallScore,
      replayProtection.processedMessagesCount > 0
          ? 1.0
          : 0.8, // Replay protection score
    ];

    return scores.fold<double>(0.0, (sum, score) => sum + score) /
        scores.length;
  }

  /// Check if app needs optimization
  bool get needsOptimization => overallHealthScore < 0.7;

  @override
  String toString() =>
      'AppStats(health: ${(overallHealthScore * 100).toStringAsFixed(1)}%, uptime: ${uptime.inHours}h)';
}

/// Replay protection statistics
class ReplayProtectionStats {
  final int processedMessagesCount;
  final int blockedDuplicateCount;
  final Duration averageProcessingTime;

  const ReplayProtectionStats({
    required this.processedMessagesCount,
    required this.blockedDuplicateCount,
    required this.averageProcessingTime,
  });

  @override
  String toString() =>
      'ReplayStats(processed: $processedMessagesCount, blocked: $blockedDuplicateCount)';
}

/// App core exception
class AppCoreException implements Exception {
  final String message;
  const AppCoreException(this.message);

  @override
  String toString() => 'AppCoreException: $message';
}
