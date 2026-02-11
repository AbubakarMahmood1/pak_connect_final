/// Message priority levels for queue management and delivery optimization
enum MessagePriority {
  /// Low priority messages - least urgent, most delay tolerant
  low,

  /// Normal priority messages - default level
  normal,

  /// High priority messages - important but not urgent
  high,

  /// Urgent priority messages - immediate delivery required
  urgent,
}

/// Extension methods for MessagePriority
extension MessagePriorityExtension on MessagePriority {
  /// Get display name for the priority level
  String get displayName {
    switch (this) {
      case MessagePriority.low:
        return 'Low';
      case MessagePriority.normal:
        return 'Normal';
      case MessagePriority.high:
        return 'High';
      case MessagePriority.urgent:
        return 'Urgent';
    }
  }

  /// Get color representation for UI
  String get colorHex {
    switch (this) {
      case MessagePriority.low:
        return '#9E9E9E'; // Grey
      case MessagePriority.normal:
        return '#2196F3'; // Blue
      case MessagePriority.high:
        return '#FF9800'; // Orange
      case MessagePriority.urgent:
        return '#F44336'; // Red
    }
  }

  /// Get retry multiplier for queue management
  double get retryMultiplier {
    switch (this) {
      case MessagePriority.low:
        return 0.8;
      case MessagePriority.normal:
        return 1.0;
      case MessagePriority.high:
        return 1.2;
      case MessagePriority.urgent:
        return 1.5;
    }
  }
}
