import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/entities/message.dart';

class MessageRepository {
  static final _logger = Logger('MessageRepository');
  static const String _messagesKey = 'chat_messages';

  Future<List<Message>> getMessages(String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    final messagesJson = prefs.getStringList(_messagesKey) ?? [];
    
    return messagesJson
        .map((json) => Message.fromJson(jsonDecode(json)))
        .where((message) => message.chatId == chatId)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  Future<void> saveMessage(Message message) async {
    final prefs = await SharedPreferences.getInstance();
    final messagesJson = prefs.getStringList(_messagesKey) ?? [];
    
    // Add new message
    messagesJson.add(jsonEncode(message.toJson()));
    
    await prefs.setStringList(_messagesKey, messagesJson);
  }

  Future<void> updateMessage(Message message) async {
    final prefs = await SharedPreferences.getInstance();
    final messagesJson = prefs.getStringList(_messagesKey) ?? [];
    
    // Find and update existing message
    for (int i = 0; i < messagesJson.length; i++) {
      final existingMessage = Message.fromJson(jsonDecode(messagesJson[i]));
      if (existingMessage.id == message.id) {
        messagesJson[i] = jsonEncode(message.toJson());
        break;
      }
    }
    
    await prefs.setStringList(_messagesKey, messagesJson);
  }

  Future<void> clearMessages(String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    final messagesJson = prefs.getStringList(_messagesKey) ?? [];
    
    // Remove messages for this chat
    final filteredMessages = messagesJson
        .where((json) {
          final message = Message.fromJson(jsonDecode(json));
          return message.chatId != chatId;
        })
        .toList();
    
    await prefs.setStringList(_messagesKey, filteredMessages);
  }

  /// Delete a specific message by ID
  Future<bool> deleteMessage(String messageId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final messagesJson = prefs.getStringList(_messagesKey) ?? [];
      
      // Find and remove the message
      final filteredMessages = messagesJson.where((json) {
        final message = Message.fromJson(jsonDecode(json));
        return message.id != messageId;
      }).toList();
      
      // Check if message was found and removed
      final wasRemoved = filteredMessages.length < messagesJson.length;
      
      if (wasRemoved) {
        await prefs.setStringList(_messagesKey, filteredMessages);
      }
      
      return wasRemoved;
    } catch (e) {
      _logger.severe('❌ Failed to delete message: $e');
      return false;
    }
  }

  /// Get all messages for interaction calculations
  Future<List<Message>> getAllMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final messagesJson = prefs.getStringList(_messagesKey) ?? [];
    
    return messagesJson
        .map((json) => Message.fromJson(jsonDecode(json)))
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  /// Get messages for a specific contact (by public key/chat ID)
  Future<List<Message>> getMessagesForContact(String publicKey) async {
    final allMessages = await getAllMessages();
    
    // Filter messages where chat ID matches the public key (chatId is the contact identifier)
    return allMessages.where((message) =>
      message.chatId == publicKey || message.chatId.contains(publicKey)
    ).toList();
  }
}