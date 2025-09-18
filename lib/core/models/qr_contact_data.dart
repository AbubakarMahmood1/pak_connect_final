import 'dart:convert';
import 'dart:math';

class QRIntroduction {
  final String publicKey;
  final String displayName;  
  final String introId;
  final int generatedAt;
  
  QRIntroduction({
    required this.publicKey,
    required this.displayName,
    required this.introId, 
    required this.generatedAt,
  });
  
  static QRIntroduction generate(String publicKey, String displayName) {
    return QRIntroduction(
      publicKey: publicKey,
      displayName: displayName,
      introId: _generateIntroId(),
      generatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
  
  static String _generateIntroId() {
    // Simple unique identifier for this introduction
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = Random().nextInt(9999);
    return 'intro_${timestamp}_$random';
  }
  
  String toQRString() {
    final data = {
      'pk': publicKey,
      'name': displayName,
      'id': introId,
      'time': generatedAt,
      'type': 'pak_connect_intro'
    };
    return base64Encode(utf8.encode(jsonEncode(data)));
  }
  
  static QRIntroduction? fromQRString(String qrData) {
    try {
      final decoded = utf8.decode(base64Decode(qrData));
      final data = jsonDecode(decoded) as Map<String, dynamic>;
      
      if (data['type'] != 'pak_connect_intro') return null;
      
      return QRIntroduction(
        publicKey: data['pk'] as String,
        displayName: data['name'] as String,
        introId: data['id'] as String,
        generatedAt: data['time'] as int,
      );
    } catch (e) {
      return null;
    }
  }
  
  bool isRecentlyGenerated({int maxAgeMinutes = 30}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final ageMinutes = (now - generatedAt) / (1000 * 60);
    return ageMinutes <= maxAgeMinutes;
  }

  bool isValid({int maxAgeMinutes = 5}) {
  return isRecentlyGenerated(maxAgeMinutes: maxAgeMinutes);
}
}