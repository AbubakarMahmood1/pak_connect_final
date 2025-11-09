import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pak_connect/core/models/protocol_message.dart';

const _publicKeyStorageKey = 'ecdh_public_key_v2';

/// Serializes a [ProtocolMessage] into raw JSON bytes.
///
/// The production transports prepend compression flags that confuse the
/// test-only BLE harness. For unit tests, we bypass compression entirely and
/// feed pure JSON into [BLEMessageHandler.processReceivedData].
Uint8List protocolMessageToJsonBytes(ProtocolMessage message) {
  final json = {
    'type': message.type.index,
    'version': message.version,
    'payload': message.payload,
    'timestamp': message.timestamp.millisecondsSinceEpoch,
    'useEphemeralSigning': message.useEphemeralSigning,
    if (message.signature != null) 'signature': message.signature,
    if (message.ephemeralSigningKey != null)
      'ephemeralSigningKey': message.ephemeralSigningKey,
  };

  return Uint8List.fromList(utf8.encode(jsonEncode(json)));
}

/// Seeds the in-memory secure storage with a deterministic public key so
/// [UserPreferences.getPublicKey] returns the same identity the tests expect.
Future<void> seedTestUserPublicKey(String key) async {
  final storage = FlutterSecureStorage();
  await storage.write(key: _publicKeyStorageKey, value: key);
}
