import 'package:pak_connect/core/interfaces/i_seen_message_store.dart';

/// Lightweight in-memory seen message store for test isolation.
class TestSeenMessageStore implements ISeenMessageStore {
  final Set<String> _delivered = <String>{};
  final Set<String> _read = <String>{};

  @override
  bool hasDelivered(String messageId) => _delivered.contains(messageId);

  @override
  bool hasRead(String messageId) => _read.contains(messageId);

  @override
  Future<void> markDelivered(String messageId) async {
    _delivered.add(messageId);
  }

  @override
  Future<void> markRead(String messageId) async {
    _read.add(messageId);
  }

  @override
  Map<String, dynamic> getStatistics() => {
    'delivered': _delivered.length,
    'read': _read.length,
  };

  @override
  Future<void> clear() async {
    _delivered.clear();
    _read.clear();
  }

  @override
  Future<void> performMaintenance() async {
    // No-op for tests
  }
}
