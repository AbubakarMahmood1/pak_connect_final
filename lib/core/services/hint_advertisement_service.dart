import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Blinded hint builder/parser for manufacturer advertisements.
/// Format (6 bytes):
///   Byte0: version (0x02) | intro flag (0x80)
///   Bytes1-2: nonce (derived from session key)
///   Bytes3-5: blinded hint bytes
class HintAdvertisementService {
  static const int version = 0x02;
  static const int introFlag = 0x80;
  static const int nonceSize = 2;
  static const int hintSize = 3;
  static const int totalSize = 1 + nonceSize + hintSize;

  /// Derive a 2-byte nonce from the current session key (hex string).
  static Uint8List deriveNonce(String sessionKey) {
    final sanitized = sessionKey.isNotEmpty ? sessionKey : '0000';
    final padded = sanitized.length >= 4
        ? sanitized
        : sanitized.padRight(4, '0');
    final byte1 = int.parse(padded.substring(0, 2), radix: 16);
    final byte2 = int.parse(padded.substring(2, 4), radix: 16);
    return Uint8List.fromList([byte1, byte2]);
  }

  /// Compute the blinded hint bytes using a stable identifier and nonce.
  static Uint8List computeHintBytes({
    required String identifier,
    required Uint8List nonce,
  }) {
    final nonceHex = bytesToHex(nonce);
    final payload = utf8.encode('$identifier:$nonceHex');
    final digest = sha256.convert(payload).bytes;
    return Uint8List.fromList(digest.sublist(0, hintSize));
  }

  /// Pack nonce + hint into manufacturer data.
  static Uint8List packAdvertisement({
    required Uint8List nonce,
    required Uint8List hintBytes,
    bool isIntro = false,
  }) {
    if (nonce.length != nonceSize) {
      throw ArgumentError('Nonce must be $nonceSize bytes');
    }
    if (hintBytes.length != hintSize) {
      throw ArgumentError('Hint must be $hintSize bytes');
    }

    final data = Uint8List(totalSize);
    data[0] = isIntro ? version | introFlag : version;
    data.setRange(1, 1 + nonceSize, nonce);
    data.setRange(1 + nonceSize, totalSize, hintBytes);
    return data;
  }

  /// Parse manufacturer data into nonce + hint. Returns null if invalid.
  static ParsedHint? parseAdvertisement(Uint8List data) {
    if (data.length != totalSize) {
      return null;
    }

    final isIntro = (data[0] & introFlag) != 0;
    final baseVersion = data[0] & ~introFlag;
    if (baseVersion != version) {
      return null;
    }

    final nonce = Uint8List.fromList(data.sublist(1, 1 + nonceSize));
    final hintBytes = Uint8List.fromList(
      data.sublist(1 + nonceSize, totalSize),
    );
    return ParsedHint(nonce: nonce, hintBytes: hintBytes, isIntro: isIntro);
  }

  static String bytesToHex(Uint8List bytes) {
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
  }
}

class ParsedHint {
  final Uint8List nonce;
  final Uint8List hintBytes;
  final bool isIntro;

  const ParsedHint({
    required this.nonce,
    required this.hintBytes,
    required this.isIntro,
  });
}
