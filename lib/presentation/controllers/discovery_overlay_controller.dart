import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' as ble;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../core/security/hint_cache_manager.dart';
import '../../data/repositories/contact_repository.dart';
import '../../domain/entities/contact.dart';
import '../providers/ble_providers.dart';
import '../widgets/discovery/discovery_types.dart';

class DiscoveryOverlayState {
  const DiscoveryOverlayState({
    required this.contacts,
    required this.deviceLastSeen,
    required this.connectionAttempts,
    required this.showScannerMode,
    this.lastIncomingConnectionAt,
  });

  factory DiscoveryOverlayState.initial() => const DiscoveryOverlayState(
    contacts: {},
    deviceLastSeen: {},
    connectionAttempts: {},
    showScannerMode: true,
  );

  final Map<String, Contact> contacts;
  final Map<String, DateTime> deviceLastSeen;
  final Map<String, ConnectionAttemptState> connectionAttempts;
  final bool showScannerMode;
  final DateTime? lastIncomingConnectionAt;

  DiscoveryOverlayState copyWith({
    Map<String, Contact>? contacts,
    Map<String, DateTime>? deviceLastSeen,
    Map<String, ConnectionAttemptState>? connectionAttempts,
    bool? showScannerMode,
    DateTime? lastIncomingConnectionAt,
  }) {
    return DiscoveryOverlayState(
      contacts: contacts ?? this.contacts,
      deviceLastSeen: deviceLastSeen ?? this.deviceLastSeen,
      connectionAttempts: connectionAttempts ?? this.connectionAttempts,
      showScannerMode: showScannerMode ?? this.showScannerMode,
      lastIncomingConnectionAt:
          lastIncomingConnectionAt ?? this.lastIncomingConnectionAt,
    );
  }
}

/// Riverpod-managed controller for discovery overlay state with lifecycle-aware
/// timers and subscriptions.
class DiscoveryOverlayController extends AsyncNotifier<DiscoveryOverlayState> {
  final _logger = Logger('DiscoveryOverlayController');
  Timer? _deviceCleanupTimer;
  StreamSubscription? _peripheralSubscription;

  @override
  Future<DiscoveryOverlayState> build() async {
    ref.onDispose(_cancelResources);

    final contacts = await ContactRepository().getAllContacts();
    await _updateHintCache();
    _startCleanupTimer();
    _startPeripheralListener();

    return DiscoveryOverlayState(
      contacts: contacts,
      deviceLastSeen: {},
      connectionAttempts: {},
      showScannerMode: true,
    );
  }

  bool getUnifiedScanningState() {
    final burstStatusAsync = ref.read(burstScanningStatusProvider);
    final burstStatus = burstStatusAsync.value;
    final isBurstActive = burstStatus?.isBurstActive ?? false;
    return isBurstActive;
  }

  bool canTriggerManualScan() {
    final burstStatusAsync = ref.read(burstScanningStatusProvider);
    final burstStatus = burstStatusAsync.value;

    if (burstStatus?.isBurstActive ?? false) {
      return false;
    }

    return burstStatus?.canOverride ?? true;
  }

  void setShowScannerMode(bool value) {
    state = state.whenData(
      (current) => current.copyWith(showScannerMode: value),
    );
  }

  void cleanupStaleDevices() {
    final now = DateTime.now();
    const staleThreshold = Duration(minutes: 3);

    state = state.whenData((current) {
      final updatedLastSeen = Map<String, DateTime>.from(
        current.deviceLastSeen,
      );
      final updatedAttempts = Map<String, ConnectionAttemptState>.from(
        current.connectionAttempts,
      );

      updatedLastSeen.removeWhere((deviceId, lastSeen) {
        final isStale = now.difference(lastSeen) > staleThreshold;
        if (isStale) {
          _logger.fine('Removing stale device: $deviceId');
          updatedAttempts.remove(deviceId);
        }
        return isStale;
      });

      return current.copyWith(
        deviceLastSeen: updatedLastSeen,
        connectionAttempts: updatedAttempts,
      );
    });
  }

  void updateDeviceLastSeen(String deviceId) {
    state = state.whenData((current) {
      final updated = Map<String, DateTime>.from(current.deviceLastSeen);
      updated[deviceId] = DateTime.now();
      return current.copyWith(deviceLastSeen: updated);
    });
  }

  void setAttemptState(String deviceId, ConnectionAttemptState attemptState) {
    state = state.whenData((current) {
      final updated = Map<String, ConnectionAttemptState>.from(
        current.connectionAttempts,
      );
      updated[deviceId] = attemptState;
      return current.copyWith(connectionAttempts: updated);
    });
  }

  ConnectionAttemptState attemptStateFor(String deviceId) {
    final current = state.asData?.value;
    return current?.connectionAttempts[deviceId] ?? ConnectionAttemptState.none;
  }

  void recordIncomingConnection() {
    state = state.whenData(
      (current) => current.copyWith(lastIncomingConnectionAt: DateTime.now()),
    );
  }

  void _startCleanupTimer() {
    _deviceCleanupTimer ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => cleanupStaleDevices(),
    );
  }

  void _startPeripheralListener() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final connectionService = ref.read(connectionServiceProvider);
    if (!connectionService.isPeripheralMode) return;

    _peripheralSubscription ??= connectionService.peripheralConnectionChanges
        .distinct(
          (prev, next) =>
              prev.central.uuid == next.central.uuid &&
              prev.state == next.state,
        )
        .listen((event) {
          if (event.state == ble.ConnectionState.connected) {
            _logger.info('Incoming connection detected');
            recordIncomingConnection();
          }
        });
  }

  Future<void> _updateHintCache() async {
    try {
      await HintCacheManager.updateCache();
      _logger.fine('Hint cache updated for discovery overlay');
    } catch (e) {
      _logger.warning('Failed to update hint cache: $e');
    }
  }

  void _cancelResources() {
    _deviceCleanupTimer?.cancel();
    _peripheralSubscription?.cancel();
    _deviceCleanupTimer = null;
    _peripheralSubscription = null;
  }
}

final discoveryOverlayControllerProvider =
    AsyncNotifierProvider.autoDispose<
      DiscoveryOverlayController,
      DiscoveryOverlayState
    >(DiscoveryOverlayController.new);
