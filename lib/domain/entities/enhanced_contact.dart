// Enhanced contact entity with additional metadata and analytics

import '../../data/repositories/contact_repository.dart'
    show Contact, TrustStatus;
import '../../core/services/security_manager.dart';

/// Enhanced contact with additional metadata and interaction statistics
class EnhancedContact {
  final Contact contact;
  final Duration lastSeenAgo;
  final bool isRecentlyActive;
  final int interactionCount;
  final Duration averageResponseTime;
  final List<String> groupMemberships;

  const EnhancedContact({
    required this.contact,
    required this.lastSeenAgo,
    required this.isRecentlyActive,
    required this.interactionCount,
    required this.averageResponseTime,
    required this.groupMemberships,
  });

  // Delegate properties to underlying contact
  String get publicKey => contact.publicKey;
  String get displayName => contact.displayName;
  TrustStatus get trustStatus => contact.trustStatus;
  SecurityLevel get securityLevel => contact.securityLevel;
  DateTime get firstSeen => contact.firstSeen;
  DateTime get lastSeen => contact.lastSeen;
  DateTime? get lastSecuritySync => contact.lastSecuritySync;

  /// Get formatted display of last seen time
  String get lastSeenFormatted {
    if (lastSeenAgo.inMinutes < 1) {
      return 'Just now';
    } else if (lastSeenAgo.inHours < 1) {
      return '${lastSeenAgo.inMinutes}m ago';
    } else if (lastSeenAgo.inDays < 1) {
      return '${lastSeenAgo.inHours}h ago';
    } else if (lastSeenAgo.inDays < 7) {
      return '${lastSeenAgo.inDays}d ago';
    } else {
      return 'Over a week ago';
    }
  }

  /// Get formatted response time
  String get responseTimeFormatted {
    if (averageResponseTime.inMinutes < 1) {
      return 'Usually responds instantly';
    } else if (averageResponseTime.inHours < 1) {
      return 'Usually responds in ${averageResponseTime.inMinutes}m';
    } else if (averageResponseTime.inDays < 1) {
      return 'Usually responds in ${averageResponseTime.inHours}h';
    } else {
      return 'Usually responds slowly';
    }
  }

  /// Get security status description
  String get securityStatusDescription {
    switch (securityLevel) {
      case SecurityLevel.high:
        return 'ECDH Encrypted';
      case SecurityLevel.medium:
        return 'Paired';
      case SecurityLevel.low:
        return 'Basic Encryption';
    }
  }

  /// Get trust status description
  String get trustStatusDescription {
    switch (trustStatus) {
      case TrustStatus.verified:
        return 'Verified Contact';
      case TrustStatus.newContact:
        return 'New Contact';
      case TrustStatus.keyChanged:
        return 'Security Warning';
    }
  }

  /// Check if contact needs attention (security issues, etc.)
  bool get needsAttention {
    return trustStatus == TrustStatus.keyChanged ||
        (securityLevel == SecurityLevel.low && isRecentlyActive) ||
        contact.isSecurityStale;
  }

  /// Get attention reason
  String? get attentionReason {
    if (trustStatus == TrustStatus.keyChanged) {
      return 'Security key has changed';
    }
    if (contact.isSecurityStale) {
      return 'Security status needs refresh';
    }
    if (securityLevel == SecurityLevel.low && isRecentlyActive) {
      return 'Could upgrade to secure encryption';
    }
    return null;
  }

  /// Create copy with updated interaction data
  EnhancedContact copyWithInteractionData({
    int? interactionCount,
    Duration? averageResponseTime,
    List<String>? groupMemberships,
  }) {
    return EnhancedContact(
      contact: contact,
      lastSeenAgo: lastSeenAgo,
      isRecentlyActive: isRecentlyActive,
      interactionCount: interactionCount ?? this.interactionCount,
      averageResponseTime: averageResponseTime ?? this.averageResponseTime,
      groupMemberships: groupMemberships ?? this.groupMemberships,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EnhancedContact &&
          runtimeType == other.runtimeType &&
          contact.publicKey == other.contact.publicKey;

  @override
  int get hashCode => contact.publicKey.hashCode;

  @override
  String toString() =>
      'EnhancedContact(${contact.displayName}, ${securityLevel.name}, ${trustStatus.name})';
}
