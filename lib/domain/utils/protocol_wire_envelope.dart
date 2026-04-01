import 'dart:convert';
import 'dart:typed_data';

import '../models/protocol_message.dart';

/// Encodes raw protocol frames into a queue-safe string envelope.
///
/// Queue storage and legacy BLE send paths are string-based. Relay forwarding
/// needs to preserve complete protocol messages without re-wrapping them as
/// user text, so this helper wraps raw protocol bytes in a recognizable
/// base64 envelope.
class ProtocolWireEnvelope {
  ProtocolWireEnvelope._();

  static const String _prefix = 'pkc_proto_b64:';

  static String encodeBytes(Uint8List bytes) => '$_prefix${base64.encode(bytes)}';

  static String encodeMessage(ProtocolMessage message) =>
      encodeBytes(message.toBytes());

  static Uint8List? tryDecodeBytes(String envelope) {
    if (!envelope.startsWith(_prefix)) {
      return null;
    }

    final payload = envelope.substring(_prefix.length);
    if (payload.isEmpty) {
      return null;
    }

    try {
      return Uint8List.fromList(base64.decode(payload));
    } catch (_) {
      return null;
    }
  }

  static ProtocolMessage? tryDecodeMessage(String envelope) {
    final bytes = tryDecodeBytes(envelope);
    if (bytes == null) {
      return null;
    }

    try {
      return ProtocolMessage.fromBytes(bytes);
    } catch (_) {
      return null;
    }
  }
}
