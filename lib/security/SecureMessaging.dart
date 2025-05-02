// SecureMessaging.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

import 'KeyStorage.dart';

class SecureMessaging {
  static final SecureMessaging _instance = SecureMessaging._internal();
  factory SecureMessaging() => _instance;

  final KeyStorage _keyStorage = KeyStorage();

  static const String MESSAGING_SERVICE_UUID = "12345678-1234-5678-1234-56789abcdef3";
  static const String MESSAGING_CHARACTERISTIC_UUID = "12345678-1234-5678-1234-56789abcdef4";

  // Default MTU size - real value will be negotiated with the device
  static const int DEFAULT_MTU = 20;
  // Max payload size = MTU - header bytes (opcode, header info)
  static const int HEADER_SIZE = 3; // 1 byte for chunk type, 2 bytes for sequence number

  // Message fragment types
  static const int FRAGMENT_SINGLE = 0; // Complete message in single fragment
  static const int FRAGMENT_FIRST = 1;  // First fragment of a multi-fragment message
  static const int FRAGMENT_MIDDLE = 2; // Middle fragment of a multi-fragment message
  static const int FRAGMENT_LAST = 3;   // Last fragment of a multi-fragment message

  // Connection parameters
  static const int MAX_RETRIES = 3;
  static const int RETRY_DELAY_MS = 1000;

  // Track chunks being received for each device
  final Map<String, Map<String, dynamic>> _messageBuffers = {};

  // Store the negotiated MTU size for each connected device
  final Map<String, int> _deviceMtu = {};

  SecureMessaging._internal();

  // Encrypt a message using AES-GCM with the shared secret
  Future<Uint8List> encryptMessage(String message, String deviceId) async {
    final sharedSecret = await _keyStorage.retrieveSharedSecret(deviceId);
    if (sharedSecret == null) {
      throw Exception('No shared secret available for device $deviceId');
    }

    // Generate a random 12-byte nonce/IV
    final iv = _generateSecureNonce();

    // Set up AES-GCM cipher with the shared secret and IV
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true, // For encryption
        ParametersWithIV(KeyParameter(sharedSecret), iv),
      );

    // Encrypt the message
    final messageBytes = utf8.encode(message);
    final paddedMessage = Uint8List(messageBytes.length);
    paddedMessage.setAll(0, messageBytes);

    final ciphertext = cipher.process(paddedMessage);

    // Combine IV and ciphertext for transmission
    final result = Uint8List(iv.length + ciphertext.length);
    result.setAll(0, iv);
    result.setAll(iv.length, ciphertext);

    return result;
  }

  // Generate a secure nonce for encryption
  Uint8List _generateSecureNonce() {
    final secureRandom = FortunaRandom();
    secureRandom.seed(KeyParameter(Uint8List.fromList(
        List.generate(32, (_) => DateTime.now().microsecondsSinceEpoch % 256))));

    final iv = Uint8List(12);
    for (var i = 0; i < iv.length; i++) {
      iv[i] = secureRandom.nextUint8();
    }
    return iv;
  }

  // Decrypt a message using AES-GCM with the shared secret
  Future<String> decryptMessage(Uint8List encryptedData, String deviceId) async {
    final sharedSecret = await _keyStorage.retrieveSharedSecret(deviceId);
    if (sharedSecret == null) {
      throw Exception('No shared secret available for device $deviceId');
    }

    // Extract IV and ciphertext
    final iv = encryptedData.sublist(0, 12);
    final ciphertext = encryptedData.sublist(12);

    // Set up AES-GCM cipher with the shared secret and IV
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false, // For decryption
        ParametersWithIV(KeyParameter(sharedSecret), iv),
      );

    try {
      // Decrypt the message
      final decrypted = cipher.process(ciphertext);
      return utf8.decode(decrypted);
    } catch (e) {
      throw Exception('Failed to decrypt message: $e');
    }
  }



  // Get available payload size for a device
  int getMaxPayloadSize(String deviceId) {
    int mtu = _deviceMtu[deviceId] ?? DEFAULT_MTU;
    return mtu - HEADER_SIZE;
  }

  // Fragment a message into multiple chunks
  List<Uint8List> _fragmentMessage(Uint8List data, String deviceId) {
    final maxChunkSize = getMaxPayloadSize(deviceId);
    final results = <Uint8List>[];

    // If message fits in a single fragment
    if (data.length <= maxChunkSize) {
      final chunk = Uint8List(data.length + HEADER_SIZE);
      chunk[0] = FRAGMENT_SINGLE;
      chunk[1] = 0; // Sequence number (2 bytes)
      chunk[2] = 0;
      chunk.setRange(HEADER_SIZE, HEADER_SIZE + data.length, data);
      results.add(chunk);
      return results;
    }

    // Message needs multiple fragments
    int offset = 0;
    int seqNum = 0;

    while (offset < data.length) {
      final bytesRemaining = data.length - offset;
      final chunkSize = bytesRemaining > maxChunkSize ? maxChunkSize : bytesRemaining;
      final isFirstChunk = offset == 0;
      final isLastChunk = offset + chunkSize >= data.length;

      // Determine fragment type
      int fragmentType;
      if (isFirstChunk) {
        fragmentType = FRAGMENT_FIRST;
      } else if (isLastChunk) {
        fragmentType = FRAGMENT_LAST;
      } else {
        fragmentType = FRAGMENT_MIDDLE;
      }

      // Create fragment with header
      final chunk = Uint8List(chunkSize + HEADER_SIZE);
      chunk[0] = fragmentType;
      chunk[1] = (seqNum >> 8) & 0xFF; // High byte of sequence number
      chunk[2] = seqNum & 0xFF;        // Low byte of sequence number

      chunk.setRange(HEADER_SIZE, HEADER_SIZE + chunkSize, data.sublist(offset, offset + chunkSize));
      results.add(chunk);

      offset += chunkSize;
      seqNum++;
    }

    return results;
  }

  // Process an incoming message fragment
  void _processFragment(Uint8List fragment, String deviceId, Completer<Uint8List> completer) {
    if (fragment.length < HEADER_SIZE) {
      completer.completeError(Exception('Fragment too small: missing header'));
      return;
    }

    final fragmentType = fragment[0];
    final seqNum = (fragment[1] << 8) | fragment[2];
    final payload = fragment.sublist(HEADER_SIZE);

    // Initialize buffer for this device if needed
    if (!_messageBuffers.containsKey(deviceId)) {
      _messageBuffers[deviceId] = {
        'fragments': <int, Uint8List>{},
        'expectedFragments': -1
      };
    }

    final buffer = _messageBuffers[deviceId]!;

    switch (fragmentType) {
      case FRAGMENT_SINGLE:
      // Complete message in a single fragment
        completer.complete(payload);
        break;

      case FRAGMENT_FIRST:
      // First fragment of a multi-fragment message
        buffer['fragments'] = <int, Uint8List>{};
        buffer['fragments'][seqNum] = payload;
        break;

      case FRAGMENT_MIDDLE:
      // Middle fragment
        buffer['fragments'][seqNum] = payload;
        break;

      case FRAGMENT_LAST:
      // Last fragment - reassemble and complete
        buffer['fragments'][seqNum] = payload;

        try {
          final reassembled = _reassembleFragments(buffer['fragments']);
          completer.complete(reassembled);
          _messageBuffers.remove(deviceId); // Clean up buffer
        } catch (e) {
          completer.completeError(Exception('Failed to reassemble message: $e'));
          _messageBuffers.remove(deviceId); // Clean up on error
        }
        break;

      default:
        completer.completeError(Exception('Unknown fragment type: $fragmentType'));
    }
  }

  // Reassemble fragments into complete message
  Uint8List _reassembleFragments(Map<int, Uint8List> fragments) {
    // Sort keys to ensure correct order
    final keys = fragments.keys.toList()..sort();

    // Calculate total size
    int totalSize = 0;
    for (var key in keys) {
      totalSize += fragments[key]!.length;
    }

    // Combine fragments
    final result = Uint8List(totalSize);
    int offset = 0;

    for (var key in keys) {
      final fragment = fragments[key]!;
      result.setRange(offset, offset + fragment.length, fragment);
      offset += fragment.length;
    }

    return result;
  }

  // Clean up resources for a device
  void cleanupDevice(String deviceId) {
    _messageBuffers.remove(deviceId);
    _deviceMtu.remove(deviceId);
  }
}