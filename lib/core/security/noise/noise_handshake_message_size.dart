/// Canonical wire sizes for Noise handshake messages.
///
/// Keep these values in one place so BLE orchestration, session management, and
/// tests stay aligned with the actual wire format.
abstract final class NoiseHandshakeMessageSize {
  static const int xxMessage1 = 32; // -> e
  static const int xxMessage2 = 80; // <- e, ee, s, es
  static const int xxMessage3 = 48; // -> s, se

  static const int kkMessage1 = 48; // -> e + encrypted empty payload/MAC
  static const int kkMessage2 = 48; // <- e + encrypted empty payload/MAC
}
