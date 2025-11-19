/// Interface for group repository operations
///
/// Abstracts group storage, retrieval, and management to enable:
/// - Dependency injection
/// - Test mocking
/// - Alternative implementations
abstract class IGroupRepository {
  /// Create a new group
  Future<String> createGroup(Map<String, dynamic> groupData);

  /// Get a specific group
  Future<Map<String, dynamic>?> getGroup(String groupId);

  /// Get all groups
  Future<List<Map<String, dynamic>>> getAllGroups();

  /// Update a group
  Future<void> updateGroup(String groupId, Map<String, dynamic> updates);

  /// Delete a group
  Future<void> deleteGroup(String groupId);

  /// Save a group message
  Future<void> saveGroupMessage(String groupId, Map<String, dynamic> message);

  /// Update delivery status for a message
  Future<void> updateDeliveryStatus(
    String groupId,
    String messageId,
    String status,
  );

  /// Get messages in a group
  Future<List<Map<String, dynamic>>> getGroupMessages(
    String groupId, {
    int offset = 0,
    int limit = 50,
  });

  /// Get a specific message
  Future<Map<String, dynamic>?> getMessage(String groupId, String messageId);

  /// Get all groups for a member
  Future<List<Map<String, dynamic>>> getGroupsForMember(String memberId);

  /// Get group statistics
  Future<Map<String, dynamic>> getStatistics(String groupId);
}
