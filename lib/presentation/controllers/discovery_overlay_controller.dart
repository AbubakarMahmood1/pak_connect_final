import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../core/security/hint_cache_manager.dart';
import '../../data/repositories/contact_repository.dart';
import '../../domain/entities/contact.dart';
import '../providers/ble_providers.dart';
import '../widgets/discovery/discovery_types.dart';

/// Coordinates non-UI state for the discovery overlay so the widget can stay
/// focused on rendering.
class DiscoveryOverlayController extends ChangeNotifier {
  DiscoveryOverlayController({
    required this.ref,
    required this.logger,
    ContactRepository? contactRepository,
  }) : _contactRepository = contactRepository ?? ContactRepository();

  final WidgetRef ref;
  final Logger logger;
  final ContactRepository _contactRepository;

  Map<String, Contact> contacts = {};
  Map<String, DateTime> deviceLastSeen = {};
  Map<String, ConnectionAttemptState> connectionAttempts = {};
  bool showScannerMode = true;

  Timer? _deviceCleanupTimer;

  Future<void> initialize() async {
    contacts = await _contactRepository.getAllContacts();
    await _updateHintCache();
    _deviceCleanupTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => cleanupStaleDevices(),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _deviceCleanupTimer?.cancel();
    super.dispose();
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
    showScannerMode = value;
    notifyListeners();
  }

  void cleanupStaleDevices() {
    final now = DateTime.now();
    const staleThreshold = Duration(minutes: 3);

    deviceLastSeen.removeWhere((deviceId, lastSeen) {
      final isStale = now.difference(lastSeen) > staleThreshold;
      if (isStale) {
        logger.fine('Removing stale device: $deviceId');
        connectionAttempts.remove(deviceId);
      }
      return isStale;
    });

    notifyListeners();
  }

  void updateDeviceLastSeen(String deviceId) {
    deviceLastSeen[deviceId] = DateTime.now();
  }

  void setAttemptState(String deviceId, ConnectionAttemptState state) {
    connectionAttempts[deviceId] = state;
    notifyListeners();
  }

  ConnectionAttemptState attemptStateFor(String deviceId) {
    return connectionAttempts[deviceId] ?? ConnectionAttemptState.none;
  }

  Future<void> _updateHintCache() async {
    try {
      await HintCacheManager.updateCache();
      logger.fine('Hint cache updated for discovery overlay');
    } catch (e) {
      logger.warning('Failed to update hint cache: $e');
    }
  }
}
