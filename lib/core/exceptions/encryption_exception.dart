/// Exception thrown when encryption operations fail.
///
/// This exception is thrown when encryption cannot be completed successfully,
/// preventing the system from falling back to insecure plaintext transmission.
class EncryptionException implements Exception {
  final String message;
  final String? publicKey;
  final String? encryptionMethod;
  final Object? cause;

  EncryptionException(
    this.message, {
    this.publicKey,
    this.encryptionMethod,
    this.cause,
  });

  @override
  String toString() {
    final buffer = StringBuffer('EncryptionException: $message');
    if (encryptionMethod != null) {
      buffer.write(' (method: $encryptionMethod)');
    }
    if (publicKey != null && publicKey!.length > 8) {
      buffer.write(' (key: ${publicKey!.substring(0, 8)}...)');
    }
    if (cause != null) {
      buffer.write(' (cause: $cause)');
    }
    return buffer.toString();
  }
}
