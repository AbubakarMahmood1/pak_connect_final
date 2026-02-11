/// Security level for contact/session trust.
///
/// - [SecurityLevel.low]: Ephemeral Noise session only
/// - [SecurityLevel.medium]: Paired via 4-digit PIN (persistent)
/// - [SecurityLevel.high]: Fully verified (triple DH)
enum SecurityLevel { low, medium, high }
