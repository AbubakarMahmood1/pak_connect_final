import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';

const _publicKeyStorageKey = 'ecdh_public_key_v2';

/// Serializes a [ProtocolMessage] into the current uncompressed wire format.
///
/// Tests should exercise the same envelope shape that production direct
/// protocol handling accepts, while still disabling compression to keep the
/// byte payload stable and readable.
Uint8List protocolMessageToWireBytes(ProtocolMessage message) =>
    message.toBytes(enableCompression: false);

/// Seeds the in-memory secure storage with a deterministic public key so
/// [UserPreferences.getPublicKey] returns the same identity the tests expect.
Future<void> seedTestUserPublicKey(String key) async {
  final storage = FlutterSecureStorage();
  await storage.write(key: _publicKeyStorageKey, value: key);
}
