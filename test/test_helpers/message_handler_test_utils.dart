import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';
import 'package:pak_connect/domain/services/signing_manager.dart';

const _publicKeyStorageKey = 'ecdh_public_key_v2';

/// Serializes a [ProtocolMessage] into the current uncompressed wire format.
///
/// Tests should exercise the same envelope shape that production direct
/// protocol handling accepts, while still disabling compression to keep the
/// byte payload stable and readable.
Uint8List protocolMessageToWireBytes(ProtocolMessage message) =>
    message.toBytes(enableCompression: false);

ProtocolMessage buildV2EncryptedTestMessage({
  required String messageId,
  required String content,
  String? intendedRecipient,
  String? senderId,
  String? recipientId,
  DateTime? timestamp,
}) {
  final signingPublicKey = EphemeralKeyManager.ephemeralSigningPublicKey;
  if (signingPublicKey == null || signingPublicKey.isEmpty) {
    throw StateError(
      'Ephemeral signing key unavailable. Initialize EphemeralKeyManager before building v2 test messages.',
    );
  }

  final baseMessage = ProtocolMessage(
    type: ProtocolMessageType.textMessage,
    version: 2,
    payload: {
      'messageId': messageId,
      'content': content,
      'encrypted': true,
      'crypto': {'mode': 'noise_v1', 'modeVersion': 1},
      ...?(senderId != null ? {'senderId': senderId} : null),
      ...?(recipientId != null ? {'recipientId': recipientId} : null),
      ...?(intendedRecipient != null
          ? {'intendedRecipient': intendedRecipient}
          : null),
    },
    useEphemeralSigning: true,
    ephemeralSigningKey: signingPublicKey,
    timestamp: timestamp ?? DateTime.now(),
  );

  final signaturePayload = SigningManager.signaturePayloadForMessage(
    baseMessage,
    fallbackContent: content,
  );
  final signature = SigningManager.signMessage(
    signaturePayload,
    SecurityLevel.low,
  );
  if (signature == null || signature.isEmpty) {
    throw StateError('Failed to generate ephemeral signature for v2 test message.');
  }

  return ProtocolMessage(
    type: baseMessage.type,
    version: baseMessage.version,
    payload: baseMessage.payload,
    signature: signature,
    useEphemeralSigning: true,
    ephemeralSigningKey: signingPublicKey,
    timestamp: baseMessage.timestamp,
  );
}

String buildRelayInnerProtocolMessagePayload({
  String messageId = 'relay-inner-msg',
  String content = 'relay-ciphertext',
  String recipientId = 'recipient-key',
  String? senderId,
}) {
  final innerMessage = buildV2EncryptedTestMessage(
    messageId: messageId,
    content: content,
    recipientId: recipientId,
    senderId: senderId,
    timestamp: DateTime.fromMillisecondsSinceEpoch(1500),
  );
  return base64.encode(innerMessage.toBytes(enableCompression: false));
}

/// Seeds the in-memory secure storage with a deterministic public key so
/// [UserPreferences.getPublicKey] returns the same identity the tests expect.
Future<void> seedTestUserPublicKey(String key) async {
  final storage = FlutterSecureStorage();
  await storage.write(key: _publicKeyStorageKey, value: key);
}
