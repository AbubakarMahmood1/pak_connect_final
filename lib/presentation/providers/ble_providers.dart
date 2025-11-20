import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'dart:async';
import '../../data/services/ble_service.dart';
import '../../core/models/connection_info.dart';
import '../../core/models/spy_mode_info.dart';
import '../../core/scanning/burst_scanning_controller.dart';
import '../../core/power/adaptive_power_manager.dart';
import '../../data/repositories/chats_repository.dart';
import '../../domain/services/mesh_networking_service.dart';
import '../../domain/models/mesh_network_models.dart';
import '../../domain/entities/enhanced_message.dart';
import 'mesh_networking_provider.dart';
import '../../data/repositories/user_preferences.dart';
import '../../core/messaging/message_router.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import '../../core/app_core.dart'; // ✅ FIX #1: Import AppCore for initialization check
import '../../core/di/service_locator.dart'; // Phase 1 Part C: DI integration

// =============================================================================
// REACTIVE USERNAME PROVIDERS (RIVERPOD 3.0 MODERN APPROACH)
// =============================================================================

/// Modern AsyncNotifier for username management with real-time updates
class UsernameNotifier extends AsyncNotifier<String> {
  @override
  Future<String> build() async {
    // Initial load from storage
    return await UserPreferences().getUserName();
  }

  /// Update username with full BLE integration and real-time UI updates
  Future<void> updateUsername(String newUsername) async {
    final bleService = ref.read(bleServiceProvider);

    // Set loading state
    state = const AsyncValue.loading();

    try {
      // 1. Update username in storage
      await UserPreferences().setUserName(newUsername);

      // 2. Update BLE state manager cache
      await bleService.stateManager.setMyUserName(newUsername);

      // 3. Trigger identity re-exchange if connected
      if (bleService.isConnected) {
        await _triggerIdentityReExchange(bleService, newUsername);
      }

      // 4. Update state - this triggers UI rebuild automatically
      state = AsyncValue.data(newUsername);
    } catch (e, stackTrace) {
      // Set error state
      state = AsyncValue.error(e, stackTrace);
      rethrow;
    }
  }

  /// Trigger identity re-exchange for immediate username propagation
  Future<void> _triggerIdentityReExchange(
    BLEService bleService,
    String newUsername,
  ) async {
    try {
      await bleService.triggerIdentityReExchange();
    } catch (e) {
      // Log error but don't fail the username update
      if (kDebugMode) {
        print('Failed to re-exchange identity: $e');
      }
    }
  }
}

/// Primary username provider - use this throughout the app
final usernameProvider = AsyncNotifierProvider<UsernameNotifier, String>(() {
  return UsernameNotifier();
});

/// Legacy compatibility - redirect to modern provider
@Deprecated('Use usernameProvider instead')
final currentUsernameProvider = FutureProvider<String>((ref) async {
  return ref.watch(usernameProvider.future);
});

/// Legacy compatibility - redirect to modern provider
/// FIX-007: Added autoDispose to prevent memory leaks
@Deprecated('Use usernameProvider instead')
final usernameStreamProvider = StreamProvider.autoDispose<String>((ref) {
  return ref.watch(usernameProvider.future).asStream();
});

/// Legacy compatibility - use usernameProvider.notifier instead
@Deprecated('Use usernameProvider.notifier.updateUsername() instead')
final usernameOperationsProvider = Provider<UsernameOperations>((ref) {
  return UsernameOperations(ref);
});

// =============================================================================
// LEGACY USERNAME OPERATIONS CLASS (DEPRECATED)
// =============================================================================

/// Username operations for reactive updates with BLE integration
@Deprecated('Use usernameProvider.notifier.updateUsername() instead')
class UsernameOperations {
  final Ref _ref;

  const UsernameOperations(this._ref);

  /// Update username with full BLE state manager integration and identity re-exchange
  Future<void> updateUsernameWithBLE(String newUsername) async {
    // Delegate to modern provider
    await _ref.read(usernameProvider.notifier).updateUsername(newUsername);
  }
}

// BLE Service provider - creates service instance without initializing
// ✅ FIX #1: Lazy initialization - don't call initialize() immediately
final bleServiceProvider = Provider<BLEService>((ref) {
  // Phase 1 Part C: Register BLEService in DI container when created
  // This allows other services and widgets to access it via DI
  if (!getIt.isRegistered<BLEService>()) {
    final service = BLEService();

    // ✅ REMOVED: Immediate initialization that caused LateInitializationError
    // The service will be initialized properly by bleServiceInitializedProvider
    // after AppCore is fully ready with messageQueue available

    ref.onDispose(() {
      try {
        MessageRouter.instance.dispose();
      } catch (e) {
        // MessageRouter might not be initialized if early error occurred
      }
      service.dispose();
    });

    // Register in DI for eager access
    try {
      getIt.registerSingleton<BLEService>(service);
    } catch (e) {
      // Service already registered (idempotent)
    }

    return service;
  } else {
    // Already registered - return from DI
    return getIt<BLEService>();
  }
});

// ✅ NEW: Initialized BLE service provider - waits for AppCore to be ready
// Use this provider when you need a fully initialized BLE service
final bleServiceInitializedProvider = FutureProvider<BLEService>((ref) async {
  final service = ref.watch(bleServiceProvider);

  // Wait for AppCore to be fully initialized (messageQueue must exist)
  int attempts = 0;
  while (!AppCore.instance.isInitialized && attempts < 100) {
    await Future.delayed(Duration(milliseconds: 100));
    attempts++;
  }

  if (!AppCore.instance.isInitialized) {
    throw StateError(
      'AppCore initialization timeout after ${attempts * 100}ms',
    );
  }

  if (kDebugMode) {
    print('✅ [BLEService] Starting initialization (AppCore is ready)');
  }

  // Now it's safe to initialize - messageQueue exists
  try {
    await service.initialize();

    // Initialize MessageRouter with the BLE service (BitChat pattern)
    await MessageRouter.initialize(service);

    if (kDebugMode) {
      print('✅ [BLEService] Initialization complete with MessageRouter');
    }
  } catch (e, stackTrace) {
    if (kDebugMode) {
      print('❌ CRITICAL: BLEService initialization failed: $e');
      print('Stack trace: $stackTrace');
    }
    // Don't rethrow - let the app continue in degraded mode
  }

  return service;
});

// BLE State provider
// FIX-007: Added autoDispose to prevent memory leaks
final bleStateProvider = StreamProvider.autoDispose<BluetoothLowEnergyState>((
  ref,
) {
  final service = ref.watch(bleServiceProvider);
  return Stream.fromFuture(service.initializationComplete).asyncExpand(
    (_) => Stream.periodic(Duration(seconds: 1), (_) => service.state),
  );
});

// Discovered devices provider
// FIX-007: Added autoDispose to prevent memory leaks
final discoveredDevicesProvider = StreamProvider.autoDispose<List<Peripheral>>((
  ref,
) {
  final service = ref.watch(bleServiceProvider);
  return service.discoveredDevices;
});

// Received messages provider
// FIX-007: Added autoDispose to prevent memory leaks
final receivedMessagesProvider = StreamProvider.autoDispose<String>((ref) {
  final service = ref.watch(bleServiceProvider);
  return service.receivedMessages;
});

// FIX-007: Added autoDispose to prevent memory leaks
final connectionInfoProvider = StreamProvider.autoDispose<ConnectionInfo>((
  ref,
) {
  final service = ref.watch(bleServiceProvider);
  return service.connectionInfo;
});

// Spy mode providers
// FIX-007: Added autoDispose to prevent memory leaks
final spyModeDetectedProvider = StreamProvider.autoDispose<SpyModeInfo>((ref) {
  final bleService = ref.watch(bleServiceProvider);
  return bleService.spyModeDetected;
});

// FIX-007: Added autoDispose to prevent memory leaks
final identityRevealedProvider = StreamProvider.autoDispose<String>((ref) {
  final bleService = ref.watch(bleServiceProvider);
  return bleService.identityRevealed;
});

final chatsRepositoryProvider = Provider<ChatsRepository>((ref) {
  return ChatsRepository();
});

// Discovery data with advertisements provider
// FIX-007: Added autoDispose to prevent memory leaks
final discoveryDataProvider =
    StreamProvider.autoDispose<Map<String, DiscoveredEventArgs>>((ref) {
      final service = ref.watch(bleServiceProvider);
      return service.discoveryData;
    });

// 🆕 Deduplicated discovered devices provider (with contact recognition)
// FIX-007: Added autoDispose to prevent memory leaks
final deduplicatedDevicesProvider =
    StreamProvider.autoDispose<Map<String, DiscoveredDevice>>((ref) {
      return DeviceDeduplicationManager.uniqueDevicesStream;
    });

// =============================================================================
// BURST SCANNING INTEGRATION
// =============================================================================

/// Burst scanning controller provider - manages the integration between power manager and BLE
/// ✅ FIX #1: Now waits for fully initialized BLE service
final burstScanningControllerProvider = FutureProvider<BurstScanningController>(
  (ref) async {
    final controller = BurstScanningController();
    // ✅ Wait for initialized service (which waits for AppCore)
    final bleService = await ref.watch(bleServiceInitializedProvider.future);

    try {
      await controller.initialize(bleService);

      // 🔥 AUTO-START: Immediately begin adaptive burst scanning
      await controller.startBurstScanning();

      ref.onDispose(() {
        controller.dispose();
      });
      return controller;
    } catch (e) {
      controller.dispose();
      rethrow;
    }
  },
);

/// Eager burst scanning initializer - forces burst scanning to start during app initialization
final eagerBurstScanningProvider = FutureProvider<bool>((ref) async {
  // This provider eagerly initializes burst scanning by watching the controller
  // The act of watching ensures the controller is initialized, even if we don't use it directly
  await ref.watch(burstScanningControllerProvider.future);
  return true; // Return success flag indicating initialization completed
});

/// Burst scanning status provider - streams real-time burst scanning status
/// FIX-007: Added autoDispose to prevent memory leaks
final burstScanningStatusProvider =
    StreamProvider.autoDispose<BurstScanningStatus>((ref) {
      final controllerAsync = ref.watch(burstScanningControllerProvider);

      return controllerAsync.when(
        data: (controller) => controller.statusStream,
        loading: () => Stream.value(
          BurstScanningStatus(
            isBurstActive: false,
            currentScanInterval: 60000,
            powerStats: PowerManagementStats(
              currentScanInterval: 60000,
              currentHealthCheckInterval: 30000,
              consecutiveSuccessfulChecks: 0,
              consecutiveFailedChecks: 0,
              connectionQualityScore: 0.5,
              connectionStabilityScore: 0.5,
              timeSinceLastSuccess: Duration.zero,
              qualityMeasurementsCount: 0,
              isBurstMode: false,
              // Phase 1: Default duty cycle stats (loading state)
              powerMode: PowerMode.balanced,
              isDutyCycleScanning: false,
              batteryLevel: 100,
              isCharging: false,
              isAppInBackground: false,
            ),
          ),
        ),
        error: (error, stack) => Stream.value(
          BurstScanningStatus(
            isBurstActive: false,
            currentScanInterval: 60000,
            powerStats: PowerManagementStats(
              currentScanInterval: 60000,
              currentHealthCheckInterval: 30000,
              consecutiveSuccessfulChecks: 0,
              consecutiveFailedChecks: 0,
              connectionQualityScore: 0.5,
              connectionStabilityScore: 0.5,
              timeSinceLastSuccess: Duration.zero,
              qualityMeasurementsCount: 0,
              isBurstMode: false,
              // Phase 1: Default duty cycle stats (error state)
              powerMode: PowerMode.balanced,
              isDutyCycleScanning: false,
              batteryLevel: 100,
              isCharging: false,
              isAppInBackground: false,
            ),
          ),
        ),
      );
    });

/// Burst scanning operations provider - provides methods to control burst scanning
final burstScanningOperationsProvider = Provider<BurstScanningOperations?>((
  ref,
) {
  final controllerAsync = ref.watch(burstScanningControllerProvider);
  final bleService = ref.watch(bleServiceProvider);

  return controllerAsync.when(
    data: (controller) =>
        BurstScanningOperations(controller: controller, bleService: bleService),
    loading: () => null,
    error: (error, stack) => null,
  );
});

// =============================================================================
// MESH NETWORKING INTEGRATION WITH BLE PROVIDERS
// =============================================================================

/// Enhanced connection info provider that includes mesh networking status
final enhancedConnectionInfoProvider = Provider<EnhancedConnectionInfo>((ref) {
  final bleConnection = ref.watch(connectionInfoProvider);
  final meshStatus = ref.watch(meshNetworkStatusProvider);

  return EnhancedConnectionInfo(
    bleConnectionInfo: bleConnection,
    meshNetworkStatus: meshStatus,
  );
});

/// Combined connectivity status provider
final connectivityStatusProvider = Provider<ConnectivityStatus>((ref) {
  final bleConnection = ref.watch(connectionInfoProvider);
  final meshStatus = ref.watch(meshNetworkStatusProvider);
  final bleState = ref.watch(bleStateProvider);

  return ConnectivityStatus(
    bleConnectionInfo: bleConnection,
    meshNetworkStatus: meshStatus,
    bluetoothState: bleState,
  );
});

/// Mesh-enabled BLE operations provider
final meshEnabledBLEProvider = Provider<MeshEnabledBLEOperations>((ref) {
  final bleService = ref.watch(bleServiceProvider);
  final meshController = ref.watch(meshNetworkingControllerProvider);
  final connectivityStatus = ref.watch(connectivityStatusProvider);

  return MeshEnabledBLEOperations(
    bleService: bleService,
    meshController: meshController,
    connectivityStatus: connectivityStatus,
  );
});

/// Network health provider combining BLE and mesh health
final networkHealthProvider = Provider<NetworkHealth>((ref) {
  final bleConnection = ref.watch(connectionInfoProvider);
  final meshHealth = ref
      .watch(meshNetworkingControllerProvider)
      .getNetworkHealth();
  final bluetoothState = ref.watch(bleStateProvider);

  return NetworkHealth(
    bleConnectionInfo: bleConnection,
    meshHealth: meshHealth,
    bluetoothState: bluetoothState,
  );
});

/// Unified messaging provider that handles both direct and mesh messages
final unifiedMessagingProvider = Provider<UnifiedMessagingService>((ref) {
  final meshController = ref.watch(meshNetworkingControllerProvider);
  final bleConnection = ref.watch(connectionInfoProvider);

  return UnifiedMessagingService(
    meshController: meshController,
    bleConnectionInfo: bleConnection,
  );
});

// =============================================================================
// DATA CLASSES FOR ENHANCED BLE + MESH INTEGRATION
// =============================================================================

/// Enhanced connection information combining BLE and mesh status
class EnhancedConnectionInfo {
  final AsyncValue<ConnectionInfo> bleConnectionInfo;
  final AsyncValue<MeshNetworkStatus> meshNetworkStatus;

  const EnhancedConnectionInfo({
    required this.bleConnectionInfo,
    required this.meshNetworkStatus,
  });

  /// Check if both BLE and mesh are ready
  bool get isFullyConnected {
    final bleReady = bleConnectionInfo.asData?.value.isConnected ?? false;
    final meshReady = meshNetworkStatus.asData?.value.isInitialized ?? false;
    return bleReady && meshReady;
  }

  /// Get combined status message
  String get statusMessage {
    final bleStatus =
        bleConnectionInfo.asData?.value.statusMessage ?? 'Unknown';
    final meshReady = meshNetworkStatus.asData?.value.isInitialized ?? false;

    if (meshReady) {
      return '$bleStatus + Mesh Ready';
    } else {
      return bleStatus;
    }
  }

  /// Check if mesh relay is available
  bool get canUseRelay {
    final bleConnected = bleConnectionInfo.asData?.value.isConnected ?? false;
    final meshInitialized =
        meshNetworkStatus.asData?.value.isInitialized ?? false;
    return bleConnected && meshInitialized;
  }
}

/// Overall connectivity status
class ConnectivityStatus {
  final AsyncValue<ConnectionInfo> bleConnectionInfo;
  final AsyncValue<MeshNetworkStatus> meshNetworkStatus;
  final AsyncValue<BluetoothLowEnergyState> bluetoothState;

  const ConnectivityStatus({
    required this.bleConnectionInfo,
    required this.meshNetworkStatus,
    required this.bluetoothState,
  });

  /// Get overall connection health (0.0 - 1.0)
  double get connectionHealth {
    double health = 0.0;

    // Bluetooth state health
    final btState = bluetoothState.asData?.value;
    if (btState == BluetoothLowEnergyState.poweredOn) {
      health += 0.3;
    }

    // BLE connection health
    if (bleConnectionInfo.asData?.value.isConnected == true) {
      health += 0.4;
    }

    // Mesh networking health
    if (meshNetworkStatus.asData?.value.isInitialized == true) {
      health += 0.3;
    }

    return health;
  }

  /// Get status description
  String get statusDescription {
    if (connectionHealth >= 0.8) return 'Excellent';
    if (connectionHealth >= 0.6) return 'Good';
    if (connectionHealth >= 0.4) return 'Fair';
    if (connectionHealth >= 0.2) return 'Poor';
    return 'Disconnected';
  }

  /// Get list of active capabilities
  List<String> get activeCapabilities {
    final capabilities = <String>[];

    if (bluetoothState.asData?.value == BluetoothLowEnergyState.poweredOn) {
      capabilities.add('Bluetooth');
    }

    if (bleConnectionInfo.asData?.value.isConnected == true) {
      capabilities.add('Direct Messaging');
    }

    if (meshNetworkStatus.asData?.value.isInitialized == true) {
      capabilities.add('Mesh Relay');
    }

    return capabilities;
  }
}

/// Mesh-enabled BLE operations
class MeshEnabledBLEOperations {
  final BLEService bleService;
  final MeshNetworkingController meshController;
  final ConnectivityStatus connectivityStatus;

  const MeshEnabledBLEOperations({
    required this.bleService,
    required this.meshController,
    required this.connectivityStatus,
  });

  /// Send message using best available method (direct or mesh)
  Future<MessageSendResult> sendMessage({
    required String content,
    required String recipientPublicKey,
    bool preferDirect = true,
  }) async {
    try {
      // Check if direct connection is available to recipient
      final bleConnected =
          connectivityStatus.bleConnectionInfo.asData?.value.isConnected ??
          false;
      final connectedNodeId = bleService.currentSessionId;

      if (preferDirect &&
          bleConnected &&
          connectedNodeId == recipientPublicKey) {
        // Use direct BLE messaging
        final success = await _sendDirectMessage(content);
        return MessageSendResult(
          success: success,
          method: MessageSendMethod.direct,
          messageId: DateTime.now().millisecondsSinceEpoch.toString(),
        );
      } else {
        // Use mesh relay
        final result = await meshController.sendMeshMessage(
          content: content,
          recipientPublicKey: recipientPublicKey,
        );

        return MessageSendResult(
          success: result.isSuccess,
          method: result.isDirect
              ? MessageSendMethod.direct
              : MessageSendMethod.mesh,
          messageId: result.messageId,
          nextHop: result.nextHop,
          error: result.error,
        );
      }
    } catch (e) {
      return MessageSendResult(
        success: false,
        method: MessageSendMethod.failed,
        error: e.toString(),
      );
    }
  }

  /// Send direct BLE message
  Future<bool> _sendDirectMessage(String content) async {
    try {
      if (bleService.isPeripheralMode) {
        return await bleService.sendPeripheralMessage(content);
      } else {
        return await bleService.sendMessage(content);
      }
    } catch (e) {
      return false;
    }
  }

  /// Check message sending capabilities
  MessageSendCapabilities get sendCapabilities {
    final bleConnected =
        connectivityStatus.bleConnectionInfo.asData?.value.isConnected ?? false;
    final meshReady =
        connectivityStatus.meshNetworkStatus.asData?.value.isInitialized ??
        false;

    return MessageSendCapabilities(
      canSendDirect: bleConnected,
      canSendMesh: meshReady,
      preferredMethod: bleConnected
          ? MessageSendMethod.direct
          : MessageSendMethod.mesh,
    );
  }
}

/// Combined network health
class NetworkHealth {
  final AsyncValue<ConnectionInfo> bleConnectionInfo;
  final MeshNetworkHealth meshHealth;
  final AsyncValue<BluetoothLowEnergyState> bluetoothState;

  const NetworkHealth({
    required this.bleConnectionInfo,
    required this.meshHealth,
    required this.bluetoothState,
  });

  /// Get overall network health score (0.0 - 1.0)
  double get overallHealth {
    double totalHealth = 0.0;
    int factors = 0;

    // Bluetooth state factor (30%)
    if (bluetoothState.asData?.value == BluetoothLowEnergyState.poweredOn) {
      totalHealth += 0.3;
    }
    factors++;

    // BLE connection factor (30%)
    if (bleConnectionInfo.asData?.value.isConnected == true) {
      totalHealth += 0.3;
    }
    factors++;

    // Mesh health factor (40%)
    totalHealth += meshHealth.overallHealth * 0.4;
    factors++;

    return factors > 0 ? totalHealth : 0.0;
  }

  /// Check if network is healthy
  bool get isHealthy => overallHealth > 0.7;

  /// Get network status message
  String get statusMessage {
    if (overallHealth >= 0.8) return 'Network Excellent';
    if (overallHealth >= 0.6) return 'Network Good';
    if (overallHealth >= 0.4) return 'Network Fair';
    if (overallHealth >= 0.2) return 'Network Poor';
    return 'Network Issues';
  }

  /// Get combined issues
  List<String> get allIssues {
    final issues = <String>[];

    // Bluetooth issues
    if (bluetoothState.asData?.value != BluetoothLowEnergyState.poweredOn) {
      issues.add('Bluetooth not powered on');
    }

    // BLE connection issues
    if (bleConnectionInfo.asData?.value.isConnected != true) {
      issues.add('No BLE connection');
    }

    // Mesh issues
    issues.addAll(meshHealth.issues);

    return issues;
  }
}

/// Unified messaging service
class UnifiedMessagingService {
  final MeshNetworkingController meshController;
  final AsyncValue<ConnectionInfo> bleConnectionInfo;

  const UnifiedMessagingService({
    required this.meshController,
    required this.bleConnectionInfo,
  });

  /// Send message using the best available method
  Future<MessageSendResult> sendMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async {
    final result = await meshController.sendMeshMessage(
      content: content,
      recipientPublicKey: recipientPublicKey,
      priority: priority,
    );

    return MessageSendResult(
      success: result.isSuccess,
      method: result.isDirect
          ? MessageSendMethod.direct
          : MessageSendMethod.mesh,
      messageId: result.messageId,
      nextHop: result.nextHop,
      error: result.error,
    );
  }
}

// Supporting enums and classes

enum MessageSendMethod { direct, mesh, failed }

class MessageSendResult {
  final bool success;
  final MessageSendMethod method;
  final String? messageId;
  final String? nextHop;
  final String? error;

  const MessageSendResult({
    required this.success,
    required this.method,
    this.messageId,
    this.nextHop,
    this.error,
  });
}

class MessageSendCapabilities {
  final bool canSendDirect;
  final bool canSendMesh;
  final MessageSendMethod preferredMethod;

  const MessageSendCapabilities({
    required this.canSendDirect,
    required this.canSendMesh,
    required this.preferredMethod,
  });

  bool get hasAnyMethod => canSendDirect || canSendMesh;

  List<MessageSendMethod> get availableMethods {
    final methods = <MessageSendMethod>[];
    if (canSendDirect) methods.add(MessageSendMethod.direct);
    if (canSendMesh) methods.add(MessageSendMethod.mesh);
    return methods;
  }
}

/// Burst scanning operations class for UI control
class BurstScanningOperations {
  final BurstScanningController controller;
  final BLEService bleService;

  const BurstScanningOperations({
    required this.controller,
    required this.bleService,
  });

  /// Start burst scanning
  Future<void> startBurstScanning() async {
    await controller.startBurstScanning();
  }

  /// Stop burst scanning
  Future<void> stopBurstScanning() async {
    await controller.stopBurstScanning();
  }

  /// Trigger manual scan (overrides burst timing)
  Future<void> triggerManualScan() async {
    await controller.triggerManualScan();
  }

  /// Report connection success for adaptive power management
  void reportConnectionSuccess({
    int? rssi,
    double? connectionTime,
    bool? dataTransferSuccess,
  }) {
    controller.reportConnectionSuccess(
      rssi: rssi,
      connectionTime: connectionTime,
      dataTransferSuccess: dataTransferSuccess,
    );
  }

  /// Report connection failure for adaptive power management
  void reportConnectionFailure({
    String? reason,
    int? rssi,
    double? attemptTime,
  }) {
    controller.reportConnectionFailure(
      reason: reason,
      rssi: rssi,
      attemptTime: attemptTime,
    );
  }

  /// Get current status
  BurstScanningStatus getCurrentStatus() {
    return controller.getCurrentStatus();
  }

  /// Check if device is in peripheral mode (can't do burst scanning)
  bool get canPerformBurstScanning => !bleService.isPeripheralMode;

  /// Check if burst scanning is available
  bool get isBurstScanningAvailable {
    return canPerformBurstScanning && bleService.isBluetoothReady;
  }
}
