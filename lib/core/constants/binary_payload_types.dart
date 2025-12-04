/// Binary envelope originalType values shared across send/receive paths.
class BinaryPayloadType {
  /// ProtocolMessage bytes carried inside the binary envelope.
  static const int protocolMessage = 0x01;

  /// Media/file payloads (reserved).
  static const int media = 0x90;
}
