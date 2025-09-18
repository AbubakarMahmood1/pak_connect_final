import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/message_queue.dart';

class MessageQueueRepository {
  static const String _queueKey = 'message_queue';
  
  Future<void> queueMessage(QueuedMessage message) async {
    final prefs = await SharedPreferences.getInstance();
    final queue = await getQueue();
    queue.add(message);
    
    // Save to persistent storage
    final jsonList = queue.map((m) => {
      'id': m.id,
      'targetPublicKey': m.targetPublicKey,
      'senderPublicKey': m.senderPublicKey,
      'encryptedContent': base64Encode(m.encryptedContent),
      'queuedAt': m.queuedAt.toIso8601String(),
      'retryCount': m.retryCount,
    }).toList();
    
    await prefs.setString(_queueKey, jsonEncode(jsonList));
  }
  
  Future<List<QueuedMessage>> getMessagesForTarget(String targetPublicKey) async {
    final queue = await getQueue();
    return queue.where((m) => m.targetPublicKey == targetPublicKey).toList();
  }
  
  Future<void> removeMessage(String messageId) async {
    final queue = await getQueue();
    queue.removeWhere((m) => m.id == messageId);
    // Save updated queue...
  }
  
  Future getQueue() async {}
}