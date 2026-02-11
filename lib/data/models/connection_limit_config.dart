import 'dart:io' show Platform;
import 'package:pak_connect/domain/models/power_mode.dart';

/// Platform-aware configuration for BLE connection limits.
///
/// Different platforms have different BLE stack capabilities:
/// - Android: Typically 7-8 total connections, split between roles
/// - iOS: 8-10 as central, but only 1-2 as peripheral
/// - Desktop: Generally more capable (10+ connections)
///
/// These limits also vary by power mode to conserve battery.
class ConnectionLimitConfig {
  /// Maximum outgoing connections (we're acting as central)
  final int maxClientConnections;

  /// Maximum incoming connections (we're acting as peripheral)
  final int maxServerConnections;

  /// Maximum total connections (client + server combined)
  /// Some platforms share a connection pool between roles.
  final int maxTotalConnections;

  const ConnectionLimitConfig._({
    required this.maxClientConnections,
    required this.maxServerConnections,
    required this.maxTotalConnections,
  });

  /// Creates platform-aware limits using conservative defaults.
  ///
  /// These are safe defaults that should work on most devices.
  /// Future enhancement: Dynamic detection based on actual device capabilities.
  factory ConnectionLimitConfig.forPlatform() {
    if (Platform.isAndroid) {
      // Android: Conservative 7 connection limit (shared pool)
      // Most Android devices support 7-8 connections total
      return const ConnectionLimitConfig._(
        maxClientConnections: 7,
        maxServerConnections: 7,
        maxTotalConnections: 7, // Shared pool between roles
      );
    } else if (Platform.isIOS) {
      // iOS: Generous for central, very limited for peripheral
      // iOS restricts incoming connections heavily
      return const ConnectionLimitConfig._(
        maxClientConnections: 8,
        maxServerConnections: 1, // iOS peripheral severely limited
        maxTotalConnections: 8,
      );
    } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // Desktop: More capable hardware
      return const ConnectionLimitConfig._(
        maxClientConnections: 10,
        maxServerConnections: 10,
        maxTotalConnections: 10,
      );
    } else {
      // Unknown platform: Ultra-conservative fallback
      return const ConnectionLimitConfig._(
        maxClientConnections: 4,
        maxServerConnections: 4,
        maxTotalConnections: 4,
      );
    }
  }

  /// Creates limits based on current power mode.
  ///
  /// Lower power modes reduce connection limits to save battery:
  /// - Performance/Balanced: Full platform capabilities
  /// - Power Saver: ~50% reduction
  /// - Ultra Low Power: Minimal (2 client, 1 server)
  factory ConnectionLimitConfig.forPowerMode(PowerMode mode) {
    final base = ConnectionLimitConfig.forPlatform();

    switch (mode) {
      case PowerMode.performance:
      case PowerMode.balanced:
        // Use full platform capabilities
        return base;

      case PowerMode.powerSaver:
        // Reduce by ~50%
        return ConnectionLimitConfig._(
          maxClientConnections: (base.maxClientConnections / 2).ceil(),
          maxServerConnections: (base.maxServerConnections / 2).ceil(),
          maxTotalConnections: (base.maxTotalConnections / 2).ceil(),
        );

      case PowerMode.ultraLowPower:
        // Minimal connections (like BitChat: 2 total)
        return const ConnectionLimitConfig._(
          maxClientConnections: 2,
          maxServerConnections: 1,
          maxTotalConnections: 2,
        );
    }
  }

  /// Check if we can accept another client connection (outgoing).
  ///
  /// Returns true if:
  /// - Current client count is below max AND
  /// - Total connection count is below max
  bool canAcceptClientConnection(
    int currentClientCount,
    int currentTotalCount,
  ) {
    return currentClientCount < maxClientConnections &&
        currentTotalCount < maxTotalConnections;
  }

  /// Check if we can accept another server connection (incoming).
  ///
  /// Returns true if:
  /// - Current server count is below max AND
  /// - Total connection count is below max
  bool canAcceptServerConnection(
    int currentServerCount,
    int currentTotalCount,
  ) {
    return currentServerCount < maxServerConnections &&
        currentTotalCount < maxTotalConnections;
  }

  /// Calculate how many excess client connections need to be disconnected
  int getExcessClientConnections(
    int currentClientCount,
    int currentTotalCount,
  ) {
    final excessDueToClientLimit = currentClientCount - maxClientConnections;
    final excessDueToTotalLimit = currentTotalCount - maxTotalConnections;
    return excessDueToClientLimit > 0 || excessDueToTotalLimit > 0
        ? [
            excessDueToClientLimit,
            excessDueToTotalLimit,
          ].reduce((a, b) => a > b ? a : b)
        : 0;
  }

  @override
  String toString() {
    return 'ConnectionLimitConfig(client: $maxClientConnections, server: $maxServerConnections, total: $maxTotalConnections)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ConnectionLimitConfig &&
        other.maxClientConnections == maxClientConnections &&
        other.maxServerConnections == maxServerConnections &&
        other.maxTotalConnections == maxTotalConnections;
  }

  @override
  int get hashCode =>
      maxClientConnections.hashCode ^
      maxServerConnections.hashCode ^
      maxTotalConnections.hashCode;
}
