import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/entities/message.dart';

class MessageRepository {
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
}