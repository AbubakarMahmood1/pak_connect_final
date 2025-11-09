import 'package:pak_connect/core/utils/string_extensions.dart';
// Special recipient constants for mesh networking
// Inspired by BitChat's SpecialRecipients pattern

/// Special recipient identifiers for broadcast and system messages
///
/// This class provides sentinel values for non-point-to-point messaging.
/// BitChat Android equivalent: SpecialRecipients.kt
class SpecialRecipients {
  // Private constructor to prevent instantiation
  SpecialRecipients._();

  /// Broadcast message to all nodes in the mesh network
  ///
  /// When a message uses this as recipientId, it will be:
  /// 1. Delivered to the current node
  /// 2. Forwarded to ALL connected neighbors (with deduplication)
  /// 3. Continued to propagate through the mesh
  ///
  /// Use cases:
  /// - Network-wide announcements
  /// - Group chat in small networks
  /// - System notifications
  ///
  /// Technical: 16-character hex sentinel (all F's for easy recognition)
  static const String broadcast = 'FFFFFFFFFFFFFFFF';

  /// Check if a recipient ID represents a broadcast message
  ///
  /// Returns true if recipientId matches the broadcast sentinel.
  /// Returns false for null, empty, or regular recipient IDs.
  static bool isBroadcast(String? recipientId) {
    return recipientId == broadcast;
  }

  /// Check if a recipient ID is a special sentinel (not a real node)
  ///
  /// Returns true for any special recipient type.
  /// Currently only BROADCAST, but designed for future expansion
  /// (e.g., SYSTEM, GROUP_*, etc.)
  static bool isSpecialRecipient(String? recipientId) {
    if (recipientId == null || recipientId.isEmpty) {
      return false;
    }
    return isBroadcast(recipientId);
    // Future: || isSystem(recipientId) || isGroup(recipientId)
  }

  /// Get human-readable name for special recipient
  ///
  /// Useful for logging and UI display
  static String getRecipientName(String recipientId) {
    if (isBroadcast(recipientId)) {
      return 'Broadcast (all nodes)';
    }
    // Default: assume it's a regular node ID
    return 'Node ${recipientId.shortId(8)}...';
  }
}
