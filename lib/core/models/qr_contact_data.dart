import 'dart:convert';

class QRContactData {
  final String publicKey;
  final String displayName;
  final int timestamp;
  final String? signature;
  
  QRContactData({
    required this.publicKey,
    required this.displayName,
    required this.timestamp,
    this.signature,
  });
  
  // Compact format for QR: base64 encoded JSON
  String toQRString() {
    final json = {
      'pk': publicKey,
      'name': displayName,
      'ts': timestamp,
      if (signature != null) 'sig': signature,
    };
    return base64Encode(utf8.encode(jsonEncode(json)));
  }
  
  static QRContactData? fromQRString(String qrData) {
    try {
      final json = jsonDecode(utf8.decode(base64Decode(qrData)));
      return QRContactData(
        publicKey: json['pk'],
        displayName: json['name'],
        timestamp: json['ts'],
        signature: json['sig'],
      );
    } catch (e) {
      print('Invalid QR data: $e');
      return null;
    }
  }
  
  bool isValid() {
    // Check timestamp is within 5 minutes
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final age = now - timestamp;
    return age >= 0 && age < 300; // 5 minutes
  }
}