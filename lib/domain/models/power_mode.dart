/// Power modes for BLE scanning and connection behavior.
enum PowerMode {
  /// Full power - continuous scanning.
  performance,

  /// Balanced mode - moderate duty cycle.
  balanced,

  /// Power saver mode - reduced duty cycle.
  powerSaver,

  /// Ultra low power mode - minimal duty cycle.
  ultraLowPower,
}
