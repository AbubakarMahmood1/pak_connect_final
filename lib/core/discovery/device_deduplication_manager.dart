// File: lib/core/discovery/device_deduplication_manager.dart
import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import '../security/hint_cache_manager.dart';
import '../../domain/entities/enhanced_contact.dart';
import '../../data/repositories/intro_hint_repository.dart';
import '../../data/repositories/contact_repository.dart';

import '../security/ephemeral_key_manager.dart';

class DeviceDeduplicationManager {
  static final _logger = Logger('DeviceDeduplicationManager');

  static final Map<String, DiscoveredDevice> _uniqueDevices = {};
  static final StreamController<Map<String, DiscoveredDevice>> _devicesController =
      StreamController.broadcast();

  static Stream<Map<String, DiscoveredDevice>> get uniqueDevicesStream =>
      _devicesController.stream;

  static int get deviceCount => _uniqueDevices.length;

  // 🆕 ENHANCEMENT 3: Auto-connect callback
  // Set by BLEService to enable auto-connect functionality
  static Future<void> Function(Peripheral device, String contactName)? onKnownContactDiscovered;

  static void processDiscoveredDevice(DiscoveredEventArgs event) {
    final deviceId = event.peripheral.uuid.toString();
    final deviceIdShort = deviceId.substring(0, 8);

    _logger.info('🔍 [DEDUP] Processing device: $deviceIdShort...');

    final ephemeralHint = _extractEphemeralHint(event);

    if (ephemeralHint == null) {
      _logger.fine('🔍 [DEDUP] No ephemeral hint found for $deviceIdShort... - skipping (not our device)');
      return; // Not our device
    }

    // Self-filter: if the hint matches our own ephemeral/session fingerprint, ignore
    try {
      final myHint = EphemeralKeyManager.generateMyEphemeralKey();
      if (myHint.isNotEmpty && myHint == ephemeralHint) {
        _logger.fine('⏭️ [DEDUP] Ignoring self advertisement (hint match) for $deviceIdShort');
        return;
      }
    } catch (_) {}

    _logger.info('🔍 [DEDUP] Device $deviceIdShort... has hint: $ephemeralHint');

    final existingDevice = _uniqueDevices[deviceId];

    if (existingDevice == null) {
      // 🆕 NEW DEVICE - Create and verify (triggers auto-connect)
      _logger.info('🆕 [DEDUP] NEW DEVICE: $deviceIdShort... - creating entry and verifying contact');

      final newDevice = DiscoveredDevice(
        deviceId: deviceId,
        ephemeralHint: ephemeralHint,
        peripheral: event.peripheral,
        rssi: event.rssi,
        advertisement: event.advertisement,
        firstSeen: DateTime.now(),
        lastSeen: DateTime.now(),
      );

      _uniqueDevices[deviceId] = newDevice;
      _logger.info('✅ [DEDUP] Device $deviceIdShort... added to unique devices map - calling _verifyContactAsync()');
      _verifyContactAsync(newDevice); // This will trigger auto-connect

    } else {
      // ✅ EXISTING DEVICE - Update metadata
      _logger.fine('🔄 [DEDUP] EXISTING DEVICE: $deviceIdShort... - updating metadata (RSSI: ${event.rssi})');

      existingDevice.rssi = event.rssi;
      existingDevice.lastSeen = DateTime.now();
      existingDevice.advertisement = event.advertisement;

      // Check if ephemeral hint changed (key rotation) OR auto-connect not yet attempted
      if (existingDevice.ephemeralHint != ephemeralHint) {
        _logger.info('🔑 [DEDUP] Hint changed for $deviceIdShort... (old: ${existingDevice.ephemeralHint}, new: $ephemeralHint) - re-verifying');
        existingDevice.ephemeralHint = ephemeralHint;
        existingDevice.autoConnectAttempted = false; // Reset flag on hint change
        _verifyContactAsync(existingDevice);
      } else if (!existingDevice.autoConnectAttempted) {
        // 🆕 AUTO-CONNECT: Trigger for devices that haven't been attempted yet
        _logger.info('🔗 [DEDUP] Auto-connect not yet attempted for $deviceIdShort... - calling _verifyContactAsync()');
        _verifyContactAsync(existingDevice);
      } else {
        // 🕒 RETRY WINDOW: allow periodic re-verification/auto-connect attempts
        if (existingDevice.nextRetryAt != null && DateTime.now().isAfter(existingDevice.nextRetryAt!)) {
          _logger.info('🔁 [DEDUP] Retry window open for $deviceIdShort... - resetting attempt and re-verifying');
          existingDevice.autoConnectAttempted = false;
          _verifyContactAsync(existingDevice);
        } else {
          _logger.fine('⏭️ [DEDUP] Skipping verification for $deviceIdShort... (already attempted, hint unchanged)');
        }
      }
    }

    _devicesController.add(Map.from(_uniqueDevices));
    _logger.fine('📡 [DEDUP] Emitted updated device map (${_uniqueDevices.length} unique devices)');
  }

  static void _verifyContactAsync(DiscoveredDevice device) async {
    final deviceId = device.deviceId.substring(0, 8);
    _logger.info('🔍 [VERIFY] ========================================');
    _logger.info('🔍 [VERIFY] Starting contact verification for: $deviceId...');
    _logger.info('🔍 [VERIFY] Hint: ${device.ephemeralHint}');
    _logger.info('🔍 [VERIFY] ========================================');

    // 🔍 PRIORITY 1: Check persistent hints (MEDIUM+ security contacts with shared secrets)
    _logger.info('🔍 [VERIFY-P1] Checking persistent hints (MEDIUM+ security)...');
    final contactHint = HintCacheManager.getContactFromCache(device.ephemeralHint);

    if (contactHint != null) {
      // ✅ MEDIUM/HIGH security contact recognized via persistent hint
      final contactName = contactHint.contact.displayName;

      _logger.info('✅ [VERIFY-P1] PERSISTENT HINT MATCHED!');
      _logger.info('✅ [VERIFY-P1] Contact: $contactName');
      _logger.info('✅ [VERIFY-P1] Security: MEDIUM+ (persistent hint)');

      device.isKnownContact = true;
      device.contactInfo = contactHint.contact;

      if (kDebugMode) {
        print('✅ RECOGNIZED CONTACT (PERSISTENT HINT): $contactName ($deviceId...)');
      }

      await _triggerAutoConnect(device, contactName);
      _devicesController.add(Map.from(_uniqueDevices));
      _logger.info('✅ [VERIFY-P1] Verification complete - device map updated');
      return;
    }

    _logger.info('❌ [VERIFY-P1] No persistent hint match - checking intro hints...');

    // 🔍 PRIORITY 2: Check intro hints (QR-based temporary hints for initial connections)
    _logger.info('🔍 [VERIFY-P2] Checking intro hints (QR-based)...');
    try {
      final introHintRepo = IntroHintRepository();
      final scannedHints = await introHintRepo.getScannedHints();

      _logger.info('🔍 [VERIFY-P2] Found ${scannedHints.length} scanned intro hints');

      for (final hint in scannedHints.values) {
        if (hint.hintHex == device.ephemeralHint) {
          // ✅ Contact recognized via intro hint (QR scan)
          final contactName = hint.displayName ?? 'Unknown';

          _logger.info('✅ [VERIFY-P2] INTRO HINT MATCHED!');
          _logger.info('✅ [VERIFY-P2] Contact: $contactName');
          _logger.info('✅ [VERIFY-P2] Security: LOW (QR-based intro hint)');

          device.isKnownContact = true;

          // Try to get full contact info from ContactRepository
          _logger.fine('🔍 [VERIFY-P2] Looking up contact in repository...');
          final contactRepo = ContactRepository();
          final contacts = await contactRepo.getAllContacts();

          // Find contact by display name (best effort)
          Contact? matchedContact;
          for (final contact in contacts.values) {
            if (contact.displayName == contactName) {
              matchedContact = contact;
              break;
            }
          }

          if (matchedContact != null) {
            _logger.fine('✅ [VERIFY-P2] Found contact in repository: ${matchedContact.publicKey.substring(0, 8)}...');
            device.contactInfo = EnhancedContact(
              contact: matchedContact,
              lastSeenAgo: DateTime.now().difference(matchedContact.lastSeen),
              isRecentlyActive: DateTime.now().difference(matchedContact.lastSeen).inHours < 24,
              interactionCount: 0,
              averageResponseTime: const Duration(minutes: 5),
              groupMemberships: const [],
            );
          } else {
            _logger.fine('⚠️ [VERIFY-P2] Contact not found in repository');
          }

          if (kDebugMode) {
            print('✅ RECOGNIZED CONTACT (INTRO HINT): $contactName ($deviceId...)');
          }

          await _triggerAutoConnect(device, contactName);
          _devicesController.add(Map.from(_uniqueDevices));
          _logger.info('✅ [VERIFY-P2] Verification complete - device map updated');
          return;
        }
      }

      _logger.info('❌ [VERIFY-P2] No intro hint match - device is unknown');
    } catch (e, stackTrace) {
      _logger.warning('⚠️ [VERIFY-P2] Failed to check intro hints: $e');
      _logger.fine('Stack trace: $stackTrace');
    }

    // 🔍 PRIORITY 4: Unknown device - no hint match, but still trigger auto-connect
    _logger.info('🔍 [VERIFY-P4] No hints matched - treating as UNKNOWN device');

    device.isKnownContact = false;
    device.contactInfo = null;

    _logger.info('👤 [VERIFY-P4] Unknown device: $deviceId... (no hint match)');
    _logger.info('🔗 [VERIFY-P4] Triggering auto-connect for unknown device (PRIORITY 4)');

    // 🆕 AUTO-CONNECT: Trigger for unknown devices too (lowest priority)
    await _triggerAutoConnect(device, 'Unknown Device');

    _devicesController.add(Map.from(_uniqueDevices));
    _logger.info('✅ [VERIFY-P4] Verification complete - device map updated');
  }

  /// 🔗 Trigger auto-connect callback if registered
  static Future<void> _triggerAutoConnect(DiscoveredDevice device, String contactName) async {
    final deviceIdShort = device.deviceId.substring(0, 8);

    _logger.info('🔗 [AUTO-CONNECT] ========================================');
    _logger.info('🔗 [AUTO-CONNECT] Attempting auto-connect for: $contactName');
    _logger.info('🔗 [AUTO-CONNECT] Device: $deviceIdShort...');
    _logger.info('🔗 [AUTO-CONNECT] Known contact: ${device.isKnownContact}');

    // Mark auto-connect as attempted + schedule retry backoff
    device.autoConnectAttempted = true;
    device.lastAttempt = DateTime.now();
    device.attemptCount = (device.attemptCount) + 1;
    int backoffSecs;
    if (device.attemptCount <= 1) {
      backoffSecs = 5;
    } else if (device.attemptCount == 2) {
      backoffSecs = 10;
    } else if (device.attemptCount == 3) {
      backoffSecs = 20;
    } else {
      backoffSecs = 60; // cap
    }
    device.nextRetryAt = device.lastAttempt!.add(Duration(seconds: backoffSecs));
    _logger.info('✅ [AUTO-CONNECT] Marked attempted at ${device.lastAttempt} (retry @ ${device.nextRetryAt})');

    if (onKnownContactDiscovered == null) {
      _logger.warning('⚠️ [AUTO-CONNECT] Callback not registered - cannot proceed');
      _logger.info('🔗 [AUTO-CONNECT] ========================================');
      return;
    }

    _logger.info('✅ [AUTO-CONNECT] Callback registered - invoking...');

    try {
      await onKnownContactDiscovered!(device.peripheral, contactName);
      _logger.info('✅ [AUTO-CONNECT] Callback completed successfully for $contactName');
    } catch (e, stackTrace) {
      _logger.warning('❌ [AUTO-CONNECT] Callback failed for $contactName: $e');
      _logger.fine('Stack trace: $stackTrace');
    }

    _logger.info('🔗 [AUTO-CONNECT] ========================================');
  }

  static String? _extractEphemeralHint(DiscoveredEventArgs event) {
    for (final manufacturerData in event.advertisement.manufacturerSpecificData) {
      if (manufacturerData.id == 0x2E19 && manufacturerData.data.length >= 4) {
        return manufacturerData.data
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      }
    }
    return null;
  }

  /// 🗑️ Remove a specific device immediately (real-time cleanup)
  ///
  /// Called when a device disconnects to ensure no stale data.
  /// This is event-driven cleanup, not periodic.
  static void removeDevice(String deviceId) {
    final removed = _uniqueDevices.remove(deviceId);
    if (removed != null) {
      _devicesController.add(Map.from(_uniqueDevices));
      Logger('DeviceDeduplicationManager').fine('🗑️ Removed device: $deviceId');
    }
  }

  static void removeStaleDevices() {
    final cutoff = DateTime.now().subtract(Duration(minutes: 2));
    _uniqueDevices.removeWhere((deviceId, device) =>
        device.lastSeen.isBefore(cutoff));
    _devicesController.add(Map.from(_uniqueDevices));
  }

  static void clearAll() {
    _uniqueDevices.clear();
    _devicesController.add({});
  }

  static void dispose() {
    if (!_devicesController.isClosed) {
      _devicesController.close();
    }
    clearAll();
  }

  static Duration _staleTimeout = Duration(minutes: 2);

  static void setStaleTimeout(Duration timeout) {
    _staleTimeout = timeout;
  }

  static void removeStaleDevicesWithConfigurableTimeout() {
    final cutoff = DateTime.now().subtract(_staleTimeout);
    _uniqueDevices.removeWhere((deviceId, device) =>
        device.lastSeen.isBefore(cutoff));
    _devicesController.add(Map.from(_uniqueDevices));
  }
}

class DiscoveredDevice {
  final String deviceId;
  String ephemeralHint;
  final Peripheral peripheral;
  int rssi;
  Advertisement advertisement;
  final DateTime firstSeen;
  DateTime lastSeen;
  bool isKnownContact = false;
  EnhancedContact? contactInfo;

  // 🆕 Track if auto-connect was attempted for this device
  bool autoConnectAttempted = false;

  // 🆕 Retry/backoff tracking for robust auto-connect
  DateTime? lastAttempt;
  int attemptCount = 0;
  DateTime? nextRetryAt;


  DiscoveredDevice({
    required this.deviceId,
    required this.ephemeralHint,
    required this.peripheral,
    required this.rssi,
    required this.advertisement,
    required this.firstSeen,
    required this.lastSeen,
  });
}