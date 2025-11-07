// File: lib/core/discovery/device_deduplication_manager.dart
import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import '../security/hint_cache_manager.dart';
import '../../domain/entities/enhanced_contact.dart';
import '../../domain/entities/ephemeral_discovery_hint.dart';
import '../../data/repositories/intro_hint_repository.dart';

import '../security/ephemeral_key_manager.dart';
import '../services/hint_advertisement_service.dart';

class DeviceDeduplicationManager {
  static final _logger = Logger('DeviceDeduplicationManager');
  static const _noHintValue = 'NO_HINT';

  static final Map<String, DiscoveredDevice> _uniqueDevices = {};
  static final StreamController<Map<String, DiscoveredDevice>>
  _devicesController = StreamController.broadcast();

  static Stream<Map<String, DiscoveredDevice>> get uniqueDevicesStream =>
      _devicesController.stream;

  static int get deviceCount => _uniqueDevices.length;

  // 🆕 ENHANCEMENT 3: Auto-connect callback
  // Set by BLEService to enable auto-connect functionality
  static Future<void> Function(Peripheral device, String contactName)?
  onKnownContactDiscovered;

  static void processDiscoveredDevice(DiscoveredEventArgs event) {
    final deviceId = event.peripheral.uuid.toString();
    final deviceIdShort = deviceId.substring(0, 8);

    _logger.info('🔍 [DEDUP] Processing device: $deviceIdShort...');

    final parsedHint = _parseHintPayload(event);
    final ephemeralHint = parsedHint != null
        ? '${HintAdvertisementService.bytesToHex(parsedHint.nonce)}:${HintAdvertisementService.bytesToHex(parsedHint.hintBytes)}'
        : _noHintValue;

    if (parsedHint == null) {
      _logger.fine(
        '🔍 [DEDUP] No hint payload found for $deviceIdShort... - treating as anonymous device',
      );
    }

    // Self-filter: if the hint matches our own ephemeral/session fingerprint, ignore
    try {
      final myHint = EphemeralKeyManager.generateMyEphemeralKey();
      if (myHint.isNotEmpty && myHint == ephemeralHint) {
        _logger.fine(
          '⏭️ [DEDUP] Ignoring self advertisement (hint match) for $deviceIdShort',
        );
        return;
      }
    } catch (_) {}

    _logger.info(
      '🔍 [DEDUP] Device $deviceIdShort... has hint: $ephemeralHint',
    );

    final existingDevice = _uniqueDevices[deviceId];

    if (existingDevice == null) {
      // 🆕 NEW DEVICE - Create and verify (triggers auto-connect)
      _logger.info(
        '🆕 [DEDUP] NEW DEVICE: $deviceIdShort... - creating entry and verifying contact',
      );

      final newDevice = DiscoveredDevice(
        deviceId: deviceId,
        ephemeralHint: ephemeralHint,
        peripheral: event.peripheral,
        rssi: event.rssi,
        advertisement: event.advertisement,
        firstSeen: DateTime.now(),
        lastSeen: DateTime.now(),
        hintNonce: parsedHint != null
            ? Uint8List.fromList(parsedHint.nonce)
            : null,
        hintBytes: parsedHint != null
            ? Uint8List.fromList(parsedHint.hintBytes)
            : null,
        isIntroHint: parsedHint?.isIntro ?? false,
      );

      _uniqueDevices[deviceId] = newDevice;
      _logger.info(
        '✅ [DEDUP] Device $deviceIdShort... added to unique devices map - calling _verifyContactAsync()',
      );
      _verifyContactAsync(newDevice); // This will trigger auto-connect
    } else {
      // ✅ EXISTING DEVICE - Update metadata
      _logger.fine(
        '🔄 [DEDUP] EXISTING DEVICE: $deviceIdShort... - updating metadata (RSSI: ${event.rssi})',
      );

      existingDevice.rssi = event.rssi;
      existingDevice.lastSeen = DateTime.now();
      existingDevice.advertisement = event.advertisement;

      // Check if ephemeral hint changed (key rotation) OR auto-connect not yet attempted
      if (existingDevice.ephemeralHint != ephemeralHint) {
        _logger.info(
          '🔑 [DEDUP] Hint changed for $deviceIdShort... (old: ${existingDevice.ephemeralHint}, new: $ephemeralHint) - re-verifying',
        );
        existingDevice.ephemeralHint = ephemeralHint;
        existingDevice.autoConnectAttempted =
            false; // Reset flag on hint change
        existingDevice.hintNonce = parsedHint != null
            ? Uint8List.fromList(parsedHint.nonce)
            : null;
        existingDevice.hintBytes = parsedHint != null
            ? Uint8List.fromList(parsedHint.hintBytes)
            : null;
        existingDevice.isIntroHint = parsedHint?.isIntro ?? false;
        _verifyContactAsync(existingDevice);
      } else if (!existingDevice.autoConnectAttempted) {
        // 🆕 AUTO-CONNECT: Trigger for devices that haven't been attempted yet
        _logger.info(
          '🔗 [DEDUP] Auto-connect not yet attempted for $deviceIdShort... - calling _verifyContactAsync()',
        );
        _verifyContactAsync(existingDevice);
      } else {
        // 🕒 RETRY WINDOW: allow periodic re-verification/auto-connect attempts
        if (existingDevice.nextRetryAt != null &&
            DateTime.now().isAfter(existingDevice.nextRetryAt!)) {
          _logger.info(
            '🔁 [DEDUP] Retry window open for $deviceIdShort... - resetting attempt and re-verifying',
          );
          existingDevice.autoConnectAttempted = false;
          _verifyContactAsync(existingDevice);
        } else {
          _logger.fine(
            '⏭️ [DEDUP] Skipping verification for $deviceIdShort... (already attempted, hint unchanged)',
          );
        }
      }
    }

    _devicesController.add(Map.from(_uniqueDevices));
    _logger.fine(
      '📡 [DEDUP] Emitted updated device map (${_uniqueDevices.length} unique devices)',
    );
  }

  static void _verifyContactAsync(DiscoveredDevice device) async {
    final deviceId = device.deviceId.substring(0, 8);
    _logger.info('🔍 [VERIFY] ========================================');
    _logger.info('🔍 [VERIFY] Starting contact verification for: $deviceId...');
    _logger.info('🔍 [VERIFY] Hint: ${device.ephemeralHint}');
    _logger.info('🔍 [VERIFY] ========================================');

    final parsed = _parseHintPayloadFromDevice(device);

    _logger.info('🔍 [VERIFY-P1] Checking blinded persistent hints...');
    ContactHint? contactHint;
    if (parsed != null && parsed.hintBytes.isNotEmpty && !parsed.isIntro) {
      contactHint = await HintCacheManager.matchBlindedHint(
        nonce: parsed.nonce,
        hintBytes: parsed.hintBytes,
      );
    } else if (parsed == null) {
      _logger.info(
        'ℹ️ [VERIFY] No hint payload available for ${device.deviceId.substring(0, 8)}...',
      );
    }

    if (contactHint != null) {
      // ✅ MEDIUM/HIGH security contact recognized via persistent hint
      final contactName = contactHint.contact.contact.displayName;

      _logger.info('✅ [VERIFY-P1] PERSISTENT HINT MATCHED!');
      _logger.info('✅ [VERIFY-P1] Contact: $contactName');
      _logger.info('✅ [VERIFY-P1] Security: MEDIUM+ (persistent hint)');

      device.isKnownContact = true;
      device.contactInfo = contactHint.contact;

      if (kDebugMode) {
        print(
          '✅ RECOGNIZED CONTACT (PERSISTENT HINT): $contactName ($deviceId...)',
        );
      }

      await _triggerAutoConnect(device, contactName);
      _devicesController.add(Map.from(_uniqueDevices));
      _logger.info('✅ [VERIFY-P1] Verification complete - device map updated');
      return;
    }

    _logger.info(
      '❌ [VERIFY-P1] No persistent hint match - checking intro hints...',
    );

    if (parsed == null) {
      _logger.info('❌ [VERIFY-P2] Cannot evaluate intro hints without payload');
    } else {
      // 🔍 PRIORITY 2: Check intro hints (QR-based temporary hints for initial connections)
      _logger.info('🔍 [VERIFY-P2] Checking intro hints (QR-based)...');
      try {
        final introMatch = await _findMatchingIntro(parsed);

        if (introMatch != null) {
          final contactName = introMatch.displayName ?? 'Unknown';

          _logger.info('✅ [VERIFY-P2] INTRO HINT MATCHED!');
          _logger.info('✅ [VERIFY-P2] Contact: $contactName');

          device.isKnownContact = true;

          if (kDebugMode) {
            print(
              '✅ RECOGNIZED CONTACT (INTRO HINT): $contactName ($deviceId...)',
            );
          }

          await _triggerAutoConnect(device, contactName);
          _devicesController.add(Map.from(_uniqueDevices));
          _logger.info(
            '✅ [VERIFY-P2] Verification complete - device map updated',
          );
          return;
        }

        _logger.info('❌ [VERIFY-P2] No intro hint match - device is unknown');
      } catch (e, stackTrace) {
        _logger.warning('⚠️ [VERIFY-P2] Failed to check intro hints: $e');
        _logger.fine('Stack trace: $stackTrace');
      }
    }

    // 🔍 PRIORITY 4: Unknown device - no hint match, but still trigger auto-connect
    _logger.info(
      '🔍 [VERIFY-P4] No hints matched - treating as UNKNOWN device',
    );

    device.isKnownContact = false;
    device.contactInfo = null;

    _logger.info('👤 [VERIFY-P4] Unknown device: $deviceId... (no hint match)');
    _logger.info('⏭️ [VERIFY-P4] Auto-connect skipped for unknown device');

    _devicesController.add(Map.from(_uniqueDevices));
    _logger.info('✅ [VERIFY-P4] Verification complete - device map updated');
  }

  /// 🔗 Trigger auto-connect callback if registered
  static Future<void> _triggerAutoConnect(
    DiscoveredDevice device,
    String contactName,
  ) async {
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
    device.nextRetryAt = device.lastAttempt!.add(
      Duration(seconds: backoffSecs),
    );
    _logger.info(
      '✅ [AUTO-CONNECT] Marked attempted at ${device.lastAttempt} (retry @ ${device.nextRetryAt})',
    );

    if (onKnownContactDiscovered == null) {
      _logger.warning(
        '⚠️ [AUTO-CONNECT] Callback not registered - cannot proceed',
      );
      _logger.info(
        '🔗 [AUTO-CONNECT] ========================================',
      );
      return;
    }

    _logger.info('✅ [AUTO-CONNECT] Callback registered - invoking...');

    try {
      await onKnownContactDiscovered!(device.peripheral, contactName);
      _logger.info(
        '✅ [AUTO-CONNECT] Callback completed successfully for $contactName',
      );
    } catch (e, stackTrace) {
      _logger.warning('❌ [AUTO-CONNECT] Callback failed for $contactName: $e');
      _logger.fine('Stack trace: $stackTrace');
    }

    _logger.info('🔗 [AUTO-CONNECT] ========================================');
  }

  /// 🗑️ Remove a specific device immediately (real-time cleanup)
  ///
  /// Called when a device disconnects to ensure no stale data.
  /// This is event-driven cleanup, not periodic.
  static void removeDevice(String deviceId) {
    final removed = _uniqueDevices.remove(deviceId);
    if (removed != null) {
      _devicesController.add(Map.from(_uniqueDevices));
      Logger(
        'DeviceDeduplicationManager',
      ).fine('🗑️ Removed device: $deviceId');
    }
  }

  static Future<EphemeralDiscoveryHint?> _findMatchingIntro(
    ParsedHint parsed,
  ) async {
    final introHintRepo = IntroHintRepository();
    final scannedHints = await introHintRepo.getScannedHints();

    _logger.info(
      '🔍 [VERIFY-P2] Found ${scannedHints.length} scanned intro hints',
    );

    for (final hint in scannedHints.values) {
      if (_matchesIntroHint(parsed, hint)) {
        return hint;
      }
    }

    return null;
  }

  static bool _matchesIntroHint(
    ParsedHint parsed,
    EphemeralDiscoveryHint hint,
  ) {
    final expected = HintAdvertisementService.computeHintBytes(
      identifier: hint.hintHex,
      nonce: parsed.nonce,
    );
    return _bytesEqual(expected, parsed.hintBytes);
  }

  static ParsedHint? _parseHintPayload(DiscoveredEventArgs event) {
    return _parseHintFromAdvertisement(event.advertisement);
  }

  static ParsedHint? _parseHintPayloadFromDevice(DiscoveredDevice device) {
    if (device.hintNonce != null && device.hintBytes != null) {
      return ParsedHint(
        nonce: Uint8List.fromList(device.hintNonce!),
        hintBytes: Uint8List.fromList(device.hintBytes!),
        isIntro: device.isIntroHint,
      );
    }
    return _parseHintFromAdvertisement(device.advertisement);
  }

  static ParsedHint? _parseHintFromAdvertisement(Advertisement advertisement) {
    for (final data in advertisement.manufacturerSpecificData) {
      if (data.id == 0x2E19) {
        final parsed = HintAdvertisementService.parseAdvertisement(data.data);
        if (parsed != null) {
          return parsed;
        }
      }
    }
    return null;
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static void removeStaleDevices() {
    final cutoff = DateTime.now().subtract(Duration(minutes: 2));
    _uniqueDevices.removeWhere(
      (deviceId, device) => device.lastSeen.isBefore(cutoff),
    );
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
    _uniqueDevices.removeWhere(
      (deviceId, device) => device.lastSeen.isBefore(cutoff),
    );
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
  Uint8List? hintNonce;
  Uint8List? hintBytes;
  bool isIntroHint;

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
    this.hintNonce,
    this.hintBytes,
    this.isIntroHint = false,
  });
}
