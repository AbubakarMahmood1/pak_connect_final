import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' as ble;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../core/security/hint_cache_manager.dart';
import '../../core/models/connection_info.dart';
import '../../data/repositories/contact_repository.dart';
import '../../domain/entities/contact.dart';
import '../../domain/entities/enhanced_contact.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import '../../core/security/security_types.dart';
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
    _listenForIdentityUpdates();

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

  void _listenForIdentityUpdates() {
    // Refresh contacts map and propagate resolved identities into discovery tiles.
    ref.listen<AsyncValue<ConnectionInfo>>(connectionInfoProvider, (
      previous,
      next,
    ) {
      next.whenData((info) {
        _refreshContacts();
        unawaited(_updateResolvedContactFromConnection(info));
      });
    });
  }

  Future<void> _refreshContacts() async {
    try {
      final contacts = await ContactRepository().getAllContacts();
      state = state.whenData((current) => current.copyWith(contacts: contacts));
    } catch (e) {
      _logger.fine('Failed to refresh contacts for discovery overlay: $e');
    }
  }

  Future<void> _updateResolvedContactFromConnection(ConnectionInfo info) async {
    try {
      if (!(info.isConnected && info.otherUserName != null)) return;

      final connectionService = ref.read(connectionServiceProvider);
      final deviceId =
          connectionService.connectedDevice?.uuid.toString() ??
          connectionService.connectedCentral?.uuid.toString();
      if (deviceId == null || deviceId.isEmpty) return;

      final identifier =
          connectionService.theirPersistentPublicKey ??
          connectionService.theirPersistentKey ??
          connectionService.currentSessionId ??
          connectionService.theirEphemeralId;
      if (identifier == null || identifier.isEmpty) return;

      final contactRepo = ContactRepository();
      final contact = await contactRepo.getContactByAnyId(identifier);
      final displayName = contact?.displayName ?? info.otherUserName!;

      final enhanced = EnhancedContact(
        contact:
            contact ??
            Contact(
              publicKey: identifier,
              persistentPublicKey: identifier,
              currentEphemeralId: connectionService.theirEphemeralId,
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
        lastSeenAgo: Duration.zero,
        isRecentlyActive: true,
        interactionCount: 0,
        averageResponseTime: const Duration(minutes: 5),
        groupMemberships: const [],
      );

      DeviceDeduplicationManager.updateResolvedContact(deviceId, enhanced);
    } catch (e) {
      _logger.fine('Failed to propagate resolved identity to discovery: $e');
    }
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
            _logger.fine('Incoming connection detected');
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
    AsyncNotifierProvider<DiscoveryOverlayController, DiscoveryOverlayState>(
      DiscoveryOverlayController.new,
    );
