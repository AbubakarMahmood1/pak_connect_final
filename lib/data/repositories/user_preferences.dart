import 'package:shared_preferences/shared_preferences.dart';

class UserPreferences {
  static const String _userNameKey = 'user_display_name';
  static const String _passphraseKey = 'chat_passphrase';
  static const String _deviceIdKey = 'my_persistent_device_id';
  
  Future<String> getUserName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_userNameKey) ?? 'User';
  }
  
  Future<void> setUserName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userNameKey, name.trim());
  }
  
  // Add passphrase methods
  Future<String> getPassphrase() async {
    final prefs = await SharedPreferences.getInstance();
    String? stored = prefs.getString(_passphraseKey);
    
    if (stored == null || stored.isEmpty) {
      // Auto-generate secure passphrase
      final generated = _generatePassphrase();
      await setPassphrase(generated);
      return generated;
    }
    
    return stored;
  }
  
  Future<void> setPassphrase(String passphrase) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_passphraseKey, passphrase.trim());
  }
  
  // Generate random passphrase
  String _generatePassphrase() {
    final words = ['blue', 'red', 'cat', 'dog', 'sun', 'moon', 'fire', 'water', 'tree', 'rock'];
    final random = DateTime.now().millisecondsSinceEpoch;
    final word1 = words[random % words.length];
    final word2 = words[(random ~/ 1000) % words.length];
    final number = (random % 999) + 100; // 3 digit number
    return '$word1$number$word2';
  }

  // Get or create persistent device ID
Future<String> getOrCreateDeviceId() async {
  final prefs = await SharedPreferences.getInstance();
  String? deviceId = prefs.getString(_deviceIdKey);
  
  if (deviceId == null || deviceId.isEmpty) {
    // Generate unique device ID
    deviceId = 'dev_${DateTime.now().millisecondsSinceEpoch}';
    await prefs.setString(_deviceIdKey, deviceId);
  }
  
  return deviceId;
}

// Get existing device ID (returns null if not set)
Future<String?> getDeviceId() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_deviceIdKey);
}
}