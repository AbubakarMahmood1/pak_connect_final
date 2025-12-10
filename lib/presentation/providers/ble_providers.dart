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
import '../../domain/models/mesh_network_models.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../domain/entities/enhanced_contact.dart';
import '../../data/repositories/user_preferences.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/messaging/message_router.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import '../../core/app_core.dart'; // ✅ FIX #1: Import AppCore for initialization check
import '../../core/services/security_manager.dart';
import '../../domain/entities/contact.dart';
import '../../core/bluetooth/bluetooth_state_monitor.dart';
import '../../core/di/service_locator.dart'; // Phase 1 Part C: DI integration
import '../../core/interfaces/i_mesh_ble_service.dart';
import '../../core/interfaces/i_connection_service.dart';
import '../../core/interfaces/i_ble_service_facade.dart';
import '../../core/interfaces/i_ble_service.dart';
import '../../core/interfaces/i_ble_handshake_service.dart';
import '../../core/bluetooth/handshake_coordinator.dart';
import 'mesh_networking_provider.dart';
import 'runtime_providers.dart';
import '../../core/utils/string_extensions.dart';
import 'ble_service_facade_provider.dart';

// =============================================================================
// CORE RUNTIME NOTIFIER (BLE)
// =============================================================================

/// Aggregate BLE runtime state surfaced via Riverpod (replaces manual listeners).
class BleRuntimeState {
  final ConnectionInfo connectionInfo;
  final List<Peripheral> discoveredDevices;
  final Map<String, DiscoveredEventArgs> discoveryData;
  final SpyModeInfo? lastSpyModeEvent;
  final String? lastIdentityReveal;
  final BluetoothStateInfo? bluetoothState;
  final BluetoothStatusMessage? bluetoothMessage;
  final bool isBluetoothReady;

  const BleRuntimeState({
    required this.connectionInfo,
    required this.discoveredDevices,
    required this.discoveryData,
    required this.lastSpyModeEvent,
    required this.lastIdentityReveal,
    required this.bluetoothState,
    required this.bluetoothMessage,
    required this.isBluetoothReady,
  });

  factory BleRuntimeState.initial(IConnectionService service) {
    return BleRuntimeState(
      connectionInfo: service.currentConnectionInfo,
      discoveredDevices: const [],
      discoveryData: const {},
      lastSpyModeEvent: null,
      lastIdentityReveal: null,
      bluetoothState: null,
      bluetoothMessage: null,
      isBluetoothReady: service.isBluetoothReady,
    );
  }

  BleRuntimeState copyWith({
    ConnectionInfo? connectionInfo,
    List<Peripheral>? discoveredDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    SpyModeInfo? lastSpyModeEvent,
    String? lastIdentityReveal,
    BluetoothStateInfo? bluetoothState,
    BluetoothStatusMessage? bluetoothMessage,
    bool? isBluetoothReady,
  }) {
    return BleRuntimeState(
      connectionInfo: connectionInfo ?? this.connectionInfo,
      discoveredDevices: discoveredDevices ?? this.discoveredDevices,
      discoveryData: discoveryData ?? this.discoveryData,
      lastSpyModeEvent: lastSpyModeEvent ?? this.lastSpyModeEvent,
      lastIdentityReveal: lastIdentityReveal ?? this.lastIdentityReveal,
      bluetoothState: bluetoothState ?? this.bluetoothState,
      bluetoothMessage: bluetoothMessage ?? this.bluetoothMessage,
      isBluetoothReady: isBluetoothReady ?? this.isBluetoothReady,
    );
  }
}

/// Centralized BLE runtime lifecycle handler with ref-managed subscriptions.
class BleRuntimeNotifier extends AsyncNotifier<BleRuntimeState> {
  @override
  Future<BleRuntimeState> build() async {
    // Ensure AppCore bootstraps before wiring BLE state.
    await ref.watch(appBootstrapProvider.future);

    final connectionService = ref.watch(connectionServiceProvider);
    await _awaitInitialization(connectionService);

    final initialState = BleRuntimeState.initial(connectionService);
    state = AsyncValue.data(initialState);

    _wireStreams();
    return initialState;
  }

  void _wireStreams() {
    ref.listen<AsyncValue<ConnectionInfo>>(bleConnectionInfoStreamProvider, (
      previous,
      next,
    ) {
      next.whenData((value) {
        final current = state.asData?.value;
        if (current == null) return;
        state = AsyncValue.data(current.copyWith(connectionInfo: value));
      });
    });

    ref.listen<AsyncValue<List<Peripheral>>>(
      bleDiscoveredDevicesStreamProvider,
      (previous, next) {
        next.whenData((value) {
          final current = state.asData?.value;
          if (current == null) return;
          state = AsyncValue.data(current.copyWith(discoveredDevices: value));
        });
      },
    );

    ref.listen<AsyncValue<Map<String, DiscoveredEventArgs>>>(
      bleDiscoveryDataStreamProvider,
      (previous, next) {
        next.whenData((value) {
          final current = state.asData?.value;
          if (current == null) return;
          state = AsyncValue.data(current.copyWith(discoveryData: value));
        });
      },
    );

    ref.listen<AsyncValue<SpyModeInfo>>(bleSpyModeStreamProvider, (
      previous,
      next,
    ) {
      next.whenData((value) {
        final current = state.asData?.value;
        if (current == null) return;
        state = AsyncValue.data(current.copyWith(lastSpyModeEvent: value));
      });
    });

    ref.listen<AsyncValue<String>>(bleIdentityRevealedStreamProvider, (
      previous,
      next,
    ) {
      next.whenData((value) {
        final current = state.asData?.value;
        if (current == null) return;
        state = AsyncValue.data(current.copyWith(lastIdentityReveal: value));
      });
    });

    ref.listen<AsyncValue<BluetoothStateInfo>>(
      bleBluetoothStateStreamProvider,
      (previous, next) {
        next.whenData((value) {
          final current = state.asData?.value;
          if (current == null) return;
          final isReady = ref.read(connectionServiceProvider).isBluetoothReady;
          state = AsyncValue.data(
            current.copyWith(bluetoothState: value, isBluetoothReady: isReady),
          );
        });
      },
    );

    ref.listen<AsyncValue<BluetoothStatusMessage>>(
      bleBluetoothStatusStreamProvider,
      (previous, next) {
        next.whenData((value) {
          final current = state.asData?.value;
          if (current == null) return;
          state = AsyncValue.data(current.copyWith(bluetoothMessage: value));
        });
      },
    );

    // Identity revealed (post-handshake) → propagate to dedup so UI shows name
    ref.listen<AsyncValue<String>>(bleIdentityRevealedStreamProvider, (
      previous,
      next,
    ) {
      next.whenData((_) {
        unawaited(_propagateIdentityResolution());
      });
    });
  }

  Future<void> _awaitInitialization(IConnectionService service) async {
    if (service is IBLEServiceFacade) {
      await (service as IBLEServiceFacade).initializationComplete;
    } else if (service is IBLEService) {
      await (service as IBLEService).initializationComplete;
    }
  }

  Future<void> _propagateIdentityResolution() async {
    try {
      final connectionService = ref.read(connectionServiceProvider);
      final device = connectionService.connectedDevice;
      if (device == null) return;

      final persistentKey =
          connectionService.theirPersistentPublicKey ??
          connectionService.theirPersistentKey ??
          connectionService.currentSessionId;
      if (persistentKey == null || persistentKey.isEmpty) return;

      final contactRepo = ContactRepository();
      final contact = await contactRepo.getContactByAnyId(persistentKey);

      final displayName =
          contact?.displayName ??
          connectionService.otherUserName ??
          'User ${persistentKey.shortId(8)}';

      final enhanced = EnhancedContact(
        contact:
            contact ??
            Contact(
              publicKey: persistentKey,
              persistentPublicKey: persistentKey,
              currentEphemeralId: null,
              displayName: displayName,
              trustStatus: TrustStatus.newContact,
              securityLevel: SecurityLevel.low,
              firstSeen: DateTime.now(),
              lastSeen: DateTime.now(),
              lastSecuritySync: null,
              noisePublicKey: null,
              noiseSessionState: null,
              lastHandshakeTime: null,
              isFavorite: false,
            ),
        lastSeenAgo: contact != null
            ? DateTime.now().difference(contact.lastSeen)
            : Duration.zero,
        isRecentlyActive: contact != null
            ? DateTime.now().difference(contact.lastSeen).inHours < 24
            : true,
        interactionCount: 0,
        averageResponseTime: const Duration(minutes: 5),
        groupMemberships: const [],
      );

      DeviceDeduplicationManager.updateResolvedContact(
        device.uuid.toString(),
        enhanced,
      );
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('⚠️ Identity propagation failed: $e');
        print(stackTrace);
      }
    }
  }
}

/// Provider exposing BLE runtime state.
final bleRuntimeProvider =
    AsyncNotifierProvider<BleRuntimeNotifier, BleRuntimeState>(
      () => BleRuntimeNotifier(),
    );

// =============================================================================
// CORE BLE STREAM BRIDGES (Riverpod lifecycle-managed)
// =============================================================================

final bleConnectionInfoStreamProvider = StreamProvider<ConnectionInfo>((ref) {
  final service = ref.watch(connectionServiceProvider);
  return service.connectionInfo;
});

final bleDiscoveredDevicesStreamProvider = StreamProvider<List<Peripheral>>((
  ref,
) {
  final service = ref.watch(connectionServiceProvider);
  return service.discoveredDevices;
});

final bleDiscoveryDataStreamProvider =
    StreamProvider<Map<String, DiscoveredEventArgs>>((ref) {
      final service = ref.watch(connectionServiceProvider);
      return service.discoveryData;
    });

final bleSpyModeStreamProvider = StreamProvider<SpyModeInfo>((ref) {
  final service = ref.watch(connectionServiceProvider);
  return service.spyModeDetected;
});

final bleIdentityRevealedStreamProvider = StreamProvider<String>((ref) {
  final service = ref.watch(connectionServiceProvider);
  return service.identityRevealed;
});

final bleBluetoothStateStreamProvider = StreamProvider<BluetoothStateInfo>((
  ref,
) {
  final service = ref.watch(connectionServiceProvider);
  return service.bluetoothStateStream;
});

final bleBluetoothStatusStreamProvider = StreamProvider<BluetoothStatusMessage>(
  (ref) {
    final service = ref.watch(connectionServiceProvider);
    return service.bluetoothMessageStream;
  },
);

final bleHandshakePhaseStreamProvider = StreamProvider<ConnectionPhase>((ref) {
  final service = ref.watch(connectionServiceProvider);
  if (service is IBLEHandshakeService) {
    return (service as IBLEHandshakeService).handshakePhaseStream;
  }
  return const Stream.empty();
});

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
    final connectionService = ref.read(connectionServiceProvider);

    // Set loading state
    state = const AsyncValue.loading();

    try {
      // 1. Update username in storage
      await UserPreferences().setUserName(newUsername);

      // 2. Update BLE state manager cache
      await connectionService.setMyUserName(newUsername);

      // 3. Trigger identity re-exchange if connected
      if (connectionService.isConnected) {
        await _triggerIdentityReExchange(connectionService);
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
    IConnectionService connectionService,
  ) async {
    try {
      await connectionService.triggerIdentityReExchange();
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

/// Legacy compatibility - converts AsyncNotifier state to stream
/// FIX-007: Added autoDispose to prevent memory leaks
@Deprecated('Use usernameProvider instead')
final usernameStreamProvider = StreamProvider.autoDispose<String>((ref) {
  // Convert usernameProvider AsyncValue<String> to a stream of String values
  // Uses a stream controller to bridge AsyncValue updates into stream events
  final asyncValue = ref.watch(usernameProvider);
  return asyncValue.when(
    data: (username) => Stream.value(username),
    loading: () => const Stream.empty(),
    error: (error, stackTrace) => Stream.error(error, stackTrace),
  );
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

// BLE Service provider - fetches DI-registered instance or creates fallback
final bleServiceProvider = Provider<BLEService>((ref) {
  if (getIt.isRegistered<BLEService>()) {
    return getIt<BLEService>();
  }

  final service = BLEService();
  bool registered = false;

  try {
    getIt.registerSingleton<BLEService>(service);
    registered = true;
  } catch (_) {
    // Already registered elsewhere (tests may double-register)
  }

  if (!getIt.isRegistered<IMeshBleService>()) {
    try {
      getIt.registerSingleton<IMeshBleService>(service);
    } catch (_) {
      // Ignore duplicate registration failures
    }
  }
  if (!getIt.isRegistered<IConnectionService>()) {
    try {
      getIt.registerSingleton<IConnectionService>(service);
    } catch (_) {
      // Ignore duplicate registration failures
    }
  }
  if (!getIt.isRegistered<IBLEServiceFacade>()) {
    try {
      getIt.registerSingleton<IBLEServiceFacade>(service);
    } catch (_) {
      // Ignore duplicate registration failures
    }
  }

  ref.onDispose(() {
    if (registered) {
      try {
        MessageRouter.instance.dispose();
      } catch (_) {
        // Router may not be initialized in fallback contexts
      }
      service.dispose();
      try {
        getIt.unregister<BLEService>();
      } catch (_) {}
      try {
        getIt.unregister<IMeshBleService>();
      } catch (_) {}
      try {
        getIt.unregister<IConnectionService>();
      } catch (_) {}
      try {
        getIt.unregister<IBLEServiceFacade>();
      } catch (_) {}
    }
  });

  return service;
});

/// Preferred seam for new features - resolves the abstract connection service.
/// Falls back to the legacy [BLEService] provider when AppCore has not
/// registered the interface yet (e.g., widget tests).
final connectionServiceProvider = Provider<IConnectionService>((ref) {
  if (getIt.isRegistered<IConnectionService>()) {
    return getIt<IConnectionService>();
  }

  // Fallback to the legacy provider so existing tests keep working.
  return ref.watch(bleServiceProvider);
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

  if (!service.isInitialized) {
    if (kDebugMode) {
      print('✅ [BLEService] Starting initialization (AppCore is ready)');
    }

    try {
      await service.initialize();
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
  } else if (kDebugMode) {
    print('ℹ️ [BLEService] Already initialized via AppCore');
  }

  return service;
});

// BLE State provider (driven by BleRuntimeNotifier)
final bleStateProvider =
    Provider.autoDispose<AsyncValue<BluetoothLowEnergyState>>((ref) {
      final runtime = ref.watch(bleRuntimeProvider);
      return runtime.whenData((state) {
        final runtimeState = state.bluetoothState?.state;
        if (runtimeState != null) {
          return runtimeState;
        }
        return ref.read(connectionServiceProvider).state;
      });
    });

// Discovered devices provider (driven by BleRuntimeNotifier)
final discoveredDevicesProvider =
    Provider.autoDispose<AsyncValue<List<Peripheral>>>((ref) {
      return ref.watch(bleRuntimeProvider).whenData((state) {
        return state.discoveredDevices;
      });
    });

// Received messages provider
// FIX-007: Added autoDispose to prevent memory leaks
final receivedMessagesProvider = StreamProvider.autoDispose<String>((ref) {
  final service = ref.watch(connectionServiceProvider);
  return service.receivedMessages;
});

/// Peripheral connection change events (bridged through Riverpod).
final peripheralConnectionChangesProvider =
    StreamProvider.autoDispose<CentralConnectionStateChangedEventArgs>((ref) {
      final service = ref.watch(connectionServiceProvider);
      return service.peripheralConnectionChanges;
    });

// Connection info provider (driven by BleRuntimeNotifier)
final connectionInfoProvider = Provider.autoDispose<AsyncValue<ConnectionInfo>>(
  (ref) {
    return ref.watch(bleRuntimeProvider).whenData((state) {
      return state.connectionInfo;
    });
  },
);

// Spy mode providers
final spyModeDetectedProvider = Provider.autoDispose<AsyncValue<SpyModeInfo>>((
  ref,
) {
  return ref
      .watch(bleRuntimeProvider)
      .when(
        data: (state) {
          final event = state.lastSpyModeEvent;
          if (event != null) return AsyncValue.data(event);
          return const AsyncValue.loading();
        },
        loading: () => const AsyncValue.loading(),
        error: (error, stack) => AsyncValue.error(error, stack),
      );
});

final identityRevealedProvider = Provider.autoDispose<AsyncValue<String>>((
  ref,
) {
  return ref
      .watch(bleRuntimeProvider)
      .when(
        data: (state) {
          final identity = state.lastIdentityReveal;
          if (identity != null) return AsyncValue.data(identity);
          return const AsyncValue.loading();
        },
        loading: () => const AsyncValue.loading(),
        error: (error, stack) => AsyncValue.error(error, stack),
      );
});

final chatsRepositoryProvider = Provider<ChatsRepository>((ref) {
  return ChatsRepository();
});

// Discovery data with advertisements provider (driven by BleRuntimeNotifier)
final discoveryDataProvider =
    Provider.autoDispose<AsyncValue<Map<String, DiscoveredEventArgs>>>((ref) {
      return ref.watch(bleRuntimeProvider).whenData((state) {
        return state.discoveryData;
      });
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
  final connectionService = ref.watch(connectionServiceProvider);

  return controllerAsync.when(
    data: (controller) => BurstScanningOperations(
      controller: controller,
      connectionService: connectionService,
    ),
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
  final connectionService = ref.watch(connectionServiceProvider);
  final meshController = ref.watch(meshNetworkingControllerProvider);
  final connectivityStatus = ref.watch(connectivityStatusProvider);

  return MeshEnabledBLEOperations(
    connectionService: connectionService,
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
  final IConnectionService connectionService;
  final MeshNetworkingController meshController;
  final ConnectivityStatus connectivityStatus;

  const MeshEnabledBLEOperations({
    required this.connectionService,
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
      final connectedNodeId = connectionService.currentSessionId;

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
      if (connectionService.isPeripheralMode) {
        return await connectionService.sendPeripheralMessage(content);
      } else {
        return await connectionService.sendMessage(content);
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
  final IConnectionService connectionService;

  const BurstScanningOperations({
    required this.controller,
    required this.connectionService,
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

  /// Force a manual scan even if cooldown is active.
  Future<void> forceManualScan() async {
    await controller.forceBurstScanNow();
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
  bool get canPerformBurstScanning => !connectionService.isPeripheralMode;

  /// Check if burst scanning is available
  bool get isBurstScanningAvailable {
    return canPerformBurstScanning && connectionService.isBluetoothReady;
  }
}
