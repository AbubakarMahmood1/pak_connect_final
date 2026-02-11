import 'dart:typed_data';

class BinaryPayload {
  BinaryPayload({
    required this.data,
    required this.originalType,
    required this.fragmentId,
    this.ttl = 0,
    this.recipient,
    this.senderNodeId,
  });

  final Uint8List data;
  final int originalType;
  final String fragmentId;
  final int ttl;
  final String? recipient;
  final String? senderNodeId;
}
