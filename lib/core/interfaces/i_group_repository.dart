import '../../core/models/contact_group.dart';

/// Interface for group repository operations
///
/// Abstracts group storage, retrieval, and management to enable:
/// - Dependency injection
/// - Test mocking
/// - Alternative implementations
abstract class IGroupRepository {
  /// Create a new group
  Future<ContactGroup> createGroup(ContactGroup group);

  /// Get a specific group
  Future<ContactGroup?> getGroup(String groupId);

  /// Get all groups
  Future<List<ContactGroup>> getAllGroups();

  /// Update a group
  Future<void> updateGroup(ContactGroup group);

  /// Delete a group
  Future<void> deleteGroup(String groupId);

  /// Save a group message
  Future<void> saveGroupMessage(GroupMessage message);

  /// Update delivery status for a message
  Future<void> updateDeliveryStatus(
    String messageId,
    String memberKey,
    MessageDeliveryStatus status,
  );

  /// Get messages in a group
  Future<List<GroupMessage>> getGroupMessages(
    String groupId, {
    int limit = 50,
  });

  /// Get a specific message
  Future<GroupMessage?> getMessage(String messageId);

  /// Get all groups for a member
  Future<List<ContactGroup>> getGroupsForMember(String memberKey);

  /// Get group statistics
  Future<Map<String, int>> getStatistics();
}
