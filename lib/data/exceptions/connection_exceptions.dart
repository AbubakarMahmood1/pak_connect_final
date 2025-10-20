/// Exception thrown when attempting to create a connection that would exceed
/// the configured connection limit.
class ConnectionLimitException implements Exception {
  final String message;
  final int currentCount;
  final int maxCount;

  ConnectionLimitException(
    this.message, {
    required this.currentCount,
    required this.maxCount,
  });

  @override
  String toString() => 'ConnectionLimitException: $message (current: $currentCount, max: $maxCount)';
}

/// Exception thrown when attempting to perform an operation on a connection
/// that doesn't exist.
class ConnectionNotFoundException implements Exception {
  final String address;
  final String operation;

  ConnectionNotFoundException(this.address, this.operation);

  @override
  String toString() => 'ConnectionNotFoundException: No connection found for $address during $operation';
}

/// Exception thrown when advertising fails to start or stop.
class AdvertisingException implements Exception {
  final String message;
  final Object? cause;

  AdvertisingException(this.message, [this.cause]);

  @override
  String toString() => 'AdvertisingException: $message${cause != null ? ' (cause: $cause)' : ''}';
}

/// Exception thrown when scanning/discovery fails.
class DiscoveryException implements Exception {
  final String message;
  final Object? cause;

  DiscoveryException(this.message, [this.cause]);

  @override
  String toString() => 'DiscoveryException: $message${cause != null ? ' (cause: $cause)' : ''}';
}
