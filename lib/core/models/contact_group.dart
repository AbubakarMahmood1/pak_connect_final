// Contact group models for secure multi-unicast messaging
// Uses existing Noise sessions for encryption (no shared passwords)
import '../../domain/values/id_types.dart';

/// Contact group for sending messages to multiple verified contacts
class ContactGroup {
  final String id;
  final String name;
  final List<String> memberKeys; // Noise public keys of members
  final String? description;
  final DateTime created;
  final DateTime lastModified;
  ChatId get idValue => ChatId(id);

  const ContactGroup({
    required this.id,
    required this.name,
    required this.memberKeys,
    this.description,
    required this.created,
    required this.lastModified,
  });

  /// Create a new group
  factory ContactGroup.create({
    required String name,
    required List<String> memberKeys,
    String? description,
  }) {
    final now = DateTime.now();
    return ContactGroup(
      id: _generateId(),
      name: name,
      memberKeys: List.unmodifiable(memberKeys),
      description: description,
      created: now,
      lastModified: now,
    );
  }

  /// Copy with updated fields
  ContactGroup copyWith({
    String? name,
    List<String>? memberKeys,
    String? description,
    DateTime? lastModified,
  }) {
    return ContactGroup(
      id: id,
      name: name ?? this.name,
      memberKeys: memberKeys != null
          ? List.unmodifiable(memberKeys)
          : this.memberKeys,
      description: description ?? this.description,
      created: created,
      lastModified: lastModified ?? DateTime.now(),
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'memberKeys': memberKeys,
    'description': description,
    'created': created.millisecondsSinceEpoch,
    'lastModified': lastModified.millisecondsSinceEpoch,
  };

  /// Create from JSON
  factory ContactGroup.fromJson(Map<String, dynamic> json) {
    return ContactGroup(
      id: json['id'] as String,
      name: json['name'] as String,
      memberKeys: (json['memberKeys'] as List<dynamic>).cast<String>(),
      description: json['description'] as String?,
      created: DateTime.fromMillisecondsSinceEpoch(json['created'] as int),
      lastModified: DateTime.fromMillisecondsSinceEpoch(
        json['lastModified'] as int,
      ),
    );
  }

  /// Number of members in the group
  int get memberCount => memberKeys.length;

  /// Check if a contact is a member
  bool hasMember(String noisePublicKey) => memberKeys.contains(noisePublicKey);

  /// Generate a unique ID
  static String _generateId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = timestamp.hashCode.toUnsigned(32).toRadixString(16);
    return 'grp_${timestamp}_$random';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContactGroup &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'ContactGroup(id: $id, name: $name, members: $memberCount)';
}

/// Delivery status for a single message to a single member
enum MessageDeliveryStatus {
  pending, // Queued but not yet sent
  sent, // Sent via Noise session
  delivered, // Confirmed delivered
  failed, // Failed to send
}

extension MessageDeliveryStatusExtension on MessageDeliveryStatus {
  String get displayName {
    switch (this) {
      case MessageDeliveryStatus.pending:
        return 'Pending';
      case MessageDeliveryStatus.sent:
        return 'Sent';
      case MessageDeliveryStatus.delivered:
        return 'Delivered';
      case MessageDeliveryStatus.failed:
        return 'Failed';
    }
  }
}

/// Group message with per-member delivery tracking
class GroupMessage {
  final String id;
  final String groupId;
  final String senderKey; // Noise public key of sender
  final String content;
  final DateTime timestamp;
  final Map<String, MessageDeliveryStatus>
  deliveryStatus; // memberKey -> status
  MessageId get idValue => MessageId(id);
  ChatId get groupIdValue => ChatId(groupId);

  const GroupMessage({
    required this.id,
    required this.groupId,
    required this.senderKey,
    required this.content,
    required this.timestamp,
    required this.deliveryStatus,
  });

  /// Create a new group message
  factory GroupMessage.create({
    required String groupId,
    required String senderKey,
    required String content,
    required List<String> memberKeys,
  }) {
    final deliveryStatus = <String, MessageDeliveryStatus>{};
    for (final memberKey in memberKeys) {
      if (memberKey != senderKey) {
        // Don't track delivery to self
        deliveryStatus[memberKey] = MessageDeliveryStatus.pending;
      }
    }

    return GroupMessage(
      id: _generateId(),
      groupId: groupId,
      senderKey: senderKey,
      content: content,
      timestamp: DateTime.now(),
      deliveryStatus: deliveryStatus,
    );
  }

  /// Update delivery status for a member
  GroupMessage updateDeliveryStatus(
    String memberKey,
    MessageDeliveryStatus status,
  ) {
    final updatedStatus = Map<String, MessageDeliveryStatus>.from(
      deliveryStatus,
    );
    updatedStatus[memberKey] = status;

    return GroupMessage(
      id: id,
      groupId: groupId,
      senderKey: senderKey,
      content: content,
      timestamp: timestamp,
      deliveryStatus: updatedStatus,
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() => {
    'id': id,
    'groupId': groupId,
    'senderKey': senderKey,
    'content': content,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'deliveryStatus': deliveryStatus.map(
      (key, value) => MapEntry(key, value.index),
    ),
  };

  /// Create from JSON
  factory GroupMessage.fromJson(Map<String, dynamic> json) {
    final deliveryStatusMap = (json['deliveryStatus'] as Map<String, dynamic>)
        .map(
          (key, value) =>
              MapEntry(key, MessageDeliveryStatus.values[value as int]),
        );

    return GroupMessage(
      id: json['id'] as String,
      groupId: json['groupId'] as String,
      senderKey: json['senderKey'] as String,
      content: json['content'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
      deliveryStatus: deliveryStatusMap,
    );
  }

  /// Get overall delivery progress
  double get deliveryProgress {
    if (deliveryStatus.isEmpty) return 1.0; // Message to self only

    final delivered = deliveryStatus.values
        .where((status) => status == MessageDeliveryStatus.delivered)
        .length;

    return delivered / deliveryStatus.length;
  }

  /// Check if all members have received the message
  bool get isFullyDelivered {
    return deliveryStatus.values.every(
      (status) => status == MessageDeliveryStatus.delivered,
    );
  }

  /// Check if any delivery failed
  bool get hasFailures {
    return deliveryStatus.values.any(
      (status) => status == MessageDeliveryStatus.failed,
    );
  }

  /// Count of successfully delivered messages
  int get deliveredCount {
    return deliveryStatus.values
        .where((status) => status == MessageDeliveryStatus.delivered)
        .length;
  }

  /// Count of failed deliveries
  int get failedCount {
    return deliveryStatus.values
        .where((status) => status == MessageDeliveryStatus.failed)
        .length;
  }

  /// Generate a unique ID
  static String _generateId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = timestamp.hashCode.toUnsigned(32).toRadixString(16);
    return 'gm_${timestamp}_$random';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupMessage &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'GroupMessage(id: $id, group: $groupId, delivered: $deliveredCount/${deliveryStatus.length})';
}
