class ChatUtils {
  /// Generate consistent chat ID for two devices regardless of who's central/peripheral
  static String generateChatId(String deviceId1, String deviceId2) {
  // Always put the lexicographically smaller ID first for consistency
  final ids = [deviceId1, deviceId2]..sort();
  return 'persistent_chat_${ids[0]}_${ids[1]}';
}
}