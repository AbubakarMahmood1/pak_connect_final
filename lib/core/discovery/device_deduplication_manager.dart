// File: lib/core/discovery/device_deduplication_manager.dart
import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import '../security/hint_cache_manager.dart';
import '../../domain/entities/enhanced_contact.dart';
import '../../domain/entities/ephemeral_discovery_hint.dart';
import '../interfaces/i_intro_hint_repository.dart';
import 'package:get_it/get_it.dart';

import '../security/ephemeral_key_manager.dart';
import '../services/hint_advertisement_service.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

class DeviceDeduplicationManager {
  static final _logger = Logger('DeviceDeduplicationManager');
  static const _noHintValue = 'NO_HINT';

  static final Map<String, DiscoveredDevice> _uniqueDevices = {};
  static final Set<void Function(Map<String, DiscoveredDevice>)>
  _deviceListeners = {};

  static Stream<Map<String, DiscoveredDevice>> get uniqueDevicesStream =>
      Stream<Map<String, DiscoveredDevice>>.multi((controller) {
        controller.add(Map.from(_uniqueDevices));

        void listener(Map<String, DiscoveredDevice> devices) {
          controller.add(devices);
        }

        _deviceListeners.add(listener);
        controller.onCancel = () {
          _deviceListeners.remove(listener);
        };
      });

  /// Expose the placeholder used when no hint payload is present.
  static String get noHintValue => _noHintValue;

  /// Retrieve the currently tracked device (if any) for a given peripheral ID.
  static DiscoveredDevice? getDevice(String deviceId) =>
      _uniqueDevices[deviceId];

  static int get deviceCount => _uniqueDevices.length;

  // 🆕 ENHANCEMENT 3: Auto-connect callback
  // Set by BLEService to enable auto-connect functionality
  static Future<void> Function(Peripheral device, String contactName)?
  onKnownContactDiscovered;
  // Optional guard to let host services veto auto-connect attempts
  static bool Function(DiscoveredDevice device)? shouldAutoConnect;

  static void processDiscoveredDevice(DiscoveredEventArgs event) {
    final deviceId = event.peripheral.uuid.toString();
    final deviceIdShort = deviceId.shortId(8);

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

    // Merge duplicates by stable hint to avoid multiple ghost entries when
    // OS rotates addresses but the advertisement payload is the same.
    final mergedInto = _findMergeTarget(
      incomingDeviceId: deviceId,
      ephemeralHint: ephemeralHint,
    );
    if (mergedInto != null) {
      final target = _uniqueDevices[mergedInto];
      if (target != null) {
        _logger.info(
          '🔁 [DEDUP] Merging $deviceIdShort... into ${mergedInto.shortId(8)} '
          'based on matching hint',
        );
        _uniqueDevices.remove(mergedInto);
        final mergedDevice =
            DiscoveredDevice(
                deviceId: deviceId,
                ephemeralHint: ephemeralHint,
                peripheral: event.peripheral,
                rssi: event.rssi,
                advertisement: event.advertisement,
                firstSeen: target.firstSeen,
                lastSeen: DateTime.now(),
                hintNonce: parsedHint != null
                    ? Uint8List.fromList(parsedHint.nonce)
                    : target.hintNonce,
                hintBytes: parsedHint != null
                    ? Uint8List.fromList(parsedHint.hintBytes)
                    : target.hintBytes,
                isIntroHint: parsedHint?.isIntro ?? target.isIntroHint,
              )
              ..isKnownContact = target.isKnownContact
              ..contactInfo = target.contactInfo
              ..autoConnectAttempted = target.autoConnectAttempted
              ..lastAttempt = target.lastAttempt
              ..attemptCount = target.attemptCount
              ..nextRetryAt = target.nextRetryAt
              ..isRetired = false;

        _uniqueDevices[deviceId] = mergedDevice;
        _notifyListeners();
        autoConnectStrongestRssi();
        return;
      }
    }

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
      _notifyListeners();
      autoConnectStrongestRssi();
    } else {
      // ✅ EXISTING DEVICE - Update metadata
      _logger.fine(
        '🔄 [DEDUP] EXISTING DEVICE: $deviceIdShort... - updating metadata (RSSI: ${event.rssi})',
      );

      _updateDeviceFromEvent(existingDevice, event, parsedHint, ephemeralHint);
      existingDevice.isRetired = false;

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

      _notifyListeners();
      autoConnectStrongestRssi();
    }

    _logger.fine(
      '📡 [DEDUP] Emitted updated device map (${_uniqueDevices.length} unique devices)',
    );
  }

  static void _verifyContactAsync(DiscoveredDevice device) async {
    final deviceId = device.deviceId.shortId(8);
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
        'ℹ️ [VERIFY] No hint payload available for ${device.deviceId.shortId(8)}...',
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
      _notifyListeners();
      _propagateContactResolution(device);
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
          _notifyListeners();
          _propagateContactResolution(device);
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
    _logger.info(
      '⏭️ [VERIFY-P4] Verification complete (auto-connect handled by RSSI flow)',
    );

    _notifyListeners();
    _logger.info('✅ [VERIFY-P4] Verification complete - device map updated');
  }

  /// Allow external identity resolution (e.g., post Noise identity exchange) to
  /// update a device and propagate the contact across matching hints.
  static void updateResolvedContact(String deviceId, EnhancedContact contact) {
    final device = _uniqueDevices[deviceId];
    if (device == null) return;
    device.contactInfo = contact;
    device.isKnownContact = true;
    device.isRetired = false;
    _propagateContactResolution(device);
    _notifyListeners();
  }

  /// 🔗 Trigger auto-connect callback if registered
  static Future<void> _triggerAutoConnect(
    DiscoveredDevice device,
    String contactName,
  ) async {
    if (shouldAutoConnect != null && !shouldAutoConnect!(device)) {
      _logger.info(
        '⏭️ [AUTO-CONNECT] Skipping for ${device.deviceId.shortId(8)} '
        '(predicate declined)',
      );
      return;
    }

    final deviceIdShort = device.deviceId.shortId(8);

    _logger.info('🔗 [AUTO-CONNECT] ========================================');
    _logger.info('🔗 [AUTO-CONNECT] Attempting auto-connect for: $contactName');
    _logger.info('🔗 [AUTO-CONNECT] Device: $deviceIdShort...');
    _logger.info('🔗 [AUTO-CONNECT] Known contact: ${device.isKnownContact}');

    _setAutoConnectAttemptMetadata(device);

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

  /// Simple strategy: pick the strongest RSSI device that is eligible and attempt auto-connect.
  static Future<void> autoConnectStrongestRssi() async {
    if (onKnownContactDiscovered == null) {
      _logger.fine(
        'ℹ️ [AUTO-CONNECT] Callback not registered; skipping RSSI-based auto-connect',
      );
      return;
    }

    final now = DateTime.now();
    final candidates = _uniqueDevices.values.where((device) {
      // Respect retry backoff if previously attempted.
      if (device.autoConnectAttempted &&
          device.nextRetryAt != null &&
          now.isBefore(device.nextRetryAt!)) {
        return false;
      }
      if (device.isRetired) return false;
      return true;
    }).toList();

    if (candidates.isEmpty) return;

    candidates.sort((a, b) => b.rssi.compareTo(a.rssi));
    final top = candidates.first;

    if (shouldAutoConnect != null && !shouldAutoConnect!(top)) {
      _logger.info(
        '⏭️ [AUTO-CONNECT] Skipping strongest-RSSI candidate '
        '${top.deviceId.shortId(8)} (predicate declined)',
      );
      return;
    }

    final displayName =
        top.contactInfo?.contact.displayName ?? 'Unknown device';
    _logger.info(
      '🔗 [AUTO-CONNECT] Selecting strongest RSSI device: ${top.deviceId.shortId(8)} '
      '(rssi: ${top.rssi}) name: $displayName',
    );

    _setAutoConnectAttemptMetadata(top);

    try {
      await onKnownContactDiscovered!(top.peripheral, displayName);
      _logger.info(
        '✅ [AUTO-CONNECT] RSSI-based connect attempt issued for ${top.deviceId.shortId(8)}',
      );
    } catch (e, stackTrace) {
      _logger.warning(
        '⚠️ [AUTO-CONNECT] RSSI-based connect failed for ${top.deviceId.shortId(8)}: $e',
      );
      _logger.fine('Stack trace: $stackTrace');
    }
  }

  static void _setAutoConnectAttemptMetadata(DiscoveredDevice device) {
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

    // Retire noisy/ghost entries after repeated failures; a fresh advertisement
    // (with same hint) will un-retire via merge.
    if (device.attemptCount >= 4) {
      device.isRetired = true;
      _logger.info(
        '🛑 [AUTO-CONNECT] Retiring device ${device.deviceId.shortId(8)} after ${device.attemptCount} attempts',
      );
    }
  }

  /// 🗑️ Remove a specific device immediately (real-time cleanup)
  ///
  /// Called when a device disconnects to ensure no stale data.
  /// This is event-driven cleanup, not periodic.
  static void removeDevice(String deviceId) {
    final removed = _uniqueDevices.remove(deviceId);
    if (removed != null) {
      _notifyListeners();
      Logger(
        'DeviceDeduplicationManager',
      ).fine('🗑️ Removed device: $deviceId');
    }
  }

  /// Mark a device entry as retired to temporarily hide unusable/ghost entries
  /// until a fresh advertisement revives it.
  static void markRetired(String deviceId) {
    final device = _uniqueDevices[deviceId];
    if (device != null) {
      device.isRetired = true;
      _notifyListeners();
      _logger.fine('🗑️ Marked device retired: $deviceId');
    }
  }

  static Future<EphemeralDiscoveryHint?> _findMatchingIntro(
    ParsedHint parsed,
  ) async {
    final introHintRepo = GetIt.instance<IIntroHintRepository>();
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

  static String? _findMergeTarget({
    required String incomingDeviceId,
    required String ephemeralHint,
  }) {
    if (ephemeralHint == _noHintValue) return null;
    for (final entry in _uniqueDevices.entries) {
      if (entry.key == incomingDeviceId) continue;
      if (entry.value.ephemeralHint == ephemeralHint) {
        return entry.key;
      }
    }
    return null;
  }

  static void _updateDeviceFromEvent(
    DiscoveredDevice target,
    DiscoveredEventArgs event,
    ParsedHint? parsedHint,
    String ephemeralHint,
  ) {
    target.rssi = event.rssi;
    target.lastSeen = DateTime.now();
    target.advertisement = event.advertisement;
    target.ephemeralHint = ephemeralHint;
    if (parsedHint != null) {
      target.hintNonce = Uint8List.fromList(parsedHint.nonce);
      target.hintBytes = Uint8List.fromList(parsedHint.hintBytes);
      target.isIntroHint = parsedHint.isIntro;
    }
  }

  static void _propagateContactResolution(DiscoveredDevice source) {
    final resolvedContact = source.contactInfo;
    if (resolvedContact == null) return;
    final sourceChatId = resolvedContact.contact.chatId;
    for (final device in _uniqueDevices.values) {
      if (device.deviceId == source.deviceId) continue;
      final sameHint =
          source.ephemeralHint != _noHintValue &&
          device.ephemeralHint == source.ephemeralHint;
      final sameContact = device.contactInfo?.contact.chatId == sourceChatId;
      if (sameHint || sameContact) {
        device.contactInfo = resolvedContact;
        device.isKnownContact = true;
        device.isRetired = false;
      }
    }
  }

  static void removeStaleDevices() {
    final cutoff = DateTime.now().subtract(Duration(minutes: 2));
    _uniqueDevices.removeWhere(
      (deviceId, device) => device.lastSeen.isBefore(cutoff),
    );
    _notifyListeners();
  }

  static void clearAll() {
    _uniqueDevices.clear();
    _notifyListeners();
  }

  static void dispose() {
    _deviceListeners.clear();
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
    _notifyListeners();
  }

  static void _notifyListeners() {
    final snapshot = Map<String, DiscoveredDevice>.from(_uniqueDevices);
    for (final listener in List.of(_deviceListeners)) {
      try {
        listener(snapshot);
      } catch (e, stackTrace) {
        _logger.warning('Error notifying dedup listeners: $e', e, stackTrace);
      }
    }
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

  // 🛑 UI-level suppression until a fresh advertisement revives the entry.
  bool isRetired = false;

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
