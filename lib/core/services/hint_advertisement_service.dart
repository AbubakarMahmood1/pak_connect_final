// File: lib/core/services/hint_advertisement_service.dart

import 'dart:typed_data';
import '../../domain/entities/ephemeral_discovery_hint.dart';
import '../../domain/entities/sensitive_contact_hint.dart';

/// BLE Advertisement Format (6 bytes total - ultra-compressed for strict Android limits):
///
/// ```
/// Byte 0:     Version (0x01)
/// Bytes 1-3:  Intro Hint (3 bytes, or 0x00 if none) - 16.7 million combinations
/// Bytes 4-5:  Ephemeral Hint (2 bytes, or 0x00 if none) - 65,536 combinations
/// ```
///
/// Note: Aggressively compressed to fit within strict BLE advertisement limits.
/// Full calculation with overhead:
/// - Flags: 3 bytes
/// - Service UUID (128-bit): 18 bytes (includes length + type)
/// - Manufacturer Data: 10 bytes (length + type + manufacturer ID + 6 bytes data)
/// Total: 31 bytes (EXACTLY at Android limit)
class HintAdvertisementService {
  static const int version = 0x01;
  static const int introHintSize = 3;  // Reduced from 6 (still 16.7M combinations)
  static const int ephemeralHintSize = 2;  // Reduced from 3 (still 65K combinations)
  static const int totalSize = 6;  // Reduced from 10

  /// Pack hints into BLE manufacturer data
  ///
  /// Returns 6-byte array ready for BLE advertisement
  static Uint8List packAdvertisement({
    EphemeralDiscoveryHint? introHint,
    SensitiveContactHint? ephemeralHint,
  }) {
    final data = Uint8List(totalSize);

    // Byte 0: Version
    data[0] = version;

    // Bytes 1-3: Intro hint (truncated to 3 bytes, or zeros)
    if (introHint != null && introHint.isUsable) {
      // Take first 3 bytes of the 8-byte hint (most significant bytes)
      final truncatedHint = introHint.hintBytes.sublist(0, introHintSize);
      data.setRange(1, 1 + introHintSize, truncatedHint);
    } else {
      data.fillRange(1, 1 + introHintSize, 0x00);
    }

    // Bytes 4-5: Ephemeral hint (truncated to 2 bytes, or zeros)
    if (ephemeralHint != null) {
      // Take first 2 bytes of the 4-byte hint
      final truncatedHint = ephemeralHint.hintBytes.sublist(0, ephemeralHintSize);
      data.setRange(1 + introHintSize, 1 + introHintSize + ephemeralHintSize, truncatedHint);
    } else {
      data.fillRange(1 + introHintSize, 1 + introHintSize + ephemeralHintSize, 0x00);
    }

    return data;
  }

  /// Parse BLE manufacturer data into hints
  ///
  /// Returns null if data is invalid
  static ParsedHints? parseAdvertisement(Uint8List data) {
    // Validate size
    if (data.length != totalSize) {
      return null;
    }

    // Validate version
    if (data[0] != version) {
      return null;
    }

    // Extract intro hint (if not all zeros)
    Uint8List? introHintBytes;
    final introData = data.sublist(1, 1 + introHintSize);
    if (!_isAllZeros(introData)) {
      introHintBytes = Uint8List.fromList(introData);
    }

    // Extract ephemeral hint (if not all zeros)
    Uint8List? ephemeralHintBytes;
    final ephemeralData = data.sublist(1 + introHintSize, 1 + introHintSize + ephemeralHintSize);
    if (!_isAllZeros(ephemeralData)) {
      ephemeralHintBytes = Uint8List.fromList(ephemeralData);
    }

    return ParsedHints(
      introHintBytes: introHintBytes,
      ephemeralHintBytes: ephemeralHintBytes,
    );
  }

  /// Check if byte array is all zeros
  static bool _isAllZeros(Uint8List data) {
    for (final byte in data) {
      if (byte != 0x00) return false;
    }
    return true;
  }

  /// Get hex string representation of advertisement data
  static String toHexString(Uint8List data) {
    return data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ').toUpperCase();
  }

  /// Create debug string for advertisement
  static String debugString(Uint8List data) {
    final parsed = parseAdvertisement(data);
    if (parsed == null) return 'INVALID ADVERTISEMENT';

    final buffer = StringBuffer();
    buffer.writeln('BLE Advertisement ($totalSize bytes):');
    buffer.writeln('  Version: 0x${data[0].toRadixString(16).padLeft(2, '0')}');

    if (parsed.introHintBytes != null) {
      buffer.writeln('  Intro Hint (${introHintSize}B): ${_bytesToHex(parsed.introHintBytes!)}');
    } else {
      buffer.writeln('  Intro Hint: (none)');
    }

    if (parsed.ephemeralHintBytes != null) {
      buffer.writeln('  Ephemeral Hint (${ephemeralHintSize}B): ${_bytesToHex(parsed.ephemeralHintBytes!)}');
    } else {
      buffer.writeln('  Ephemeral Hint: (none)');
    }

    return buffer.toString();
  }

  static String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('').toUpperCase();
  }
}

/// Parsed hints from BLE advertisement
class ParsedHints {
  /// Intro hint bytes (null if not present)
  final Uint8List? introHintBytes;

  /// Ephemeral hint bytes (null if not present)
  final Uint8List? ephemeralHintBytes;

  ParsedHints({
    this.introHintBytes,
    this.ephemeralHintBytes,
  });

  /// Check if has intro hint
  bool get hasIntroHint => introHintBytes != null;

  /// Check if has ephemeral hint
  bool get hasEphemeralHint => ephemeralHintBytes != null;

  /// Check if has any hint
  bool get hasAnyHint => hasIntroHint || hasEphemeralHint;

  @override
  String toString() {
    return 'ParsedHints(intro: ${hasIntroHint ? 'YES' : 'NO'}, '
           'ephemeral: ${hasEphemeralHint ? 'YES' : 'NO'})';
  }
}
