import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:qr_barcode_dialog_scanner/qr_barcode_dialog_scanner.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/qr_contact_data.dart';
import '../../data/repositories/user_preferences.dart';


class QRContactScreen extends ConsumerStatefulWidget {
  const QRContactScreen({super.key});

  @override
  ConsumerState<QRContactScreen> createState() => _QRContactScreenState();
}

class _QRContactScreenState extends ConsumerState<QRContactScreen> {
  String? _myQRData;
  QRIntroduction? _scannedContact;
  bool _hasScanned = false;
  
  @override
  void initState() {
    super.initState();
    _generateMyQR();
  }
  
  Future<void> _generateMyQR() async {
  final userPrefs = UserPreferences();
  final publicKey = await userPrefs.getPublicKey();
  final displayName = await userPrefs.getUserName();
  
  // Generate simple introduction
  final introduction = QRIntroduction.generate(publicKey, displayName);
  
  // Track this QR showing session
  await _trackQRSession(introduction);

  setState(() {
    _myQRData = introduction.toQRString();
  });
}

Future<void> _trackQRSession(QRIntroduction intro) async {
  final prefs = await SharedPreferences.getInstance();
  
  // Store when I started showing this QR
  await prefs.setString('my_qr_session_${intro.introId}', jsonEncode({
    'intro_id': intro.introId,
    'started_showing': intro.generatedAt,
    'stopped_showing': null, // Will be set when QR screen closes
    'public_key': intro.publicKey,
    'display_name': intro.displayName,
  }));

  // Logger('QRContactScreen').fine('📝 Started showing QR: ${intro.introId}');
}

void _stopTrackingQRSession() async {
  try {
    final intro = QRIntroduction.fromQRString(_myQRData!);
    if (intro != null) {
      final prefs = await SharedPreferences.getInstance();
      final sessionData = prefs.getString('my_qr_session_${intro.introId}');
      
      if (sessionData != null) {
        final data = jsonDecode(sessionData);
        data['stopped_showing'] = DateTime.now().millisecondsSinceEpoch;

        await prefs.setString('my_qr_session_${intro.introId}', jsonEncode(data));
        // Logger('QRContactScreen').fine('📝 Stopped showing QR: ${intro.introId}');
      }
    }
  } catch (e) {
    // Logger('QRContactScreen').warning('Error stopping QR session tracking: $e');
  }
}
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_hasScanned ? 'Confirm Contact' : 'Share Your QR'),
        actions: [
          if (!_hasScanned)
            IconButton(
              onPressed: _startScanning,
              icon: Icon(Icons.qr_code_scanner),
              tooltip: 'Scan QR',
            ),
        ],
      ),
      body: _hasScanned ? _buildContactConfirmation() : _buildQRDisplay(),
    );
  }
  
  Widget _buildQRDisplay() {
    if (_myQRData == null) {
      return Center(child: CircularProgressIndicator());
    }
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(),
                  blurRadius: 10,
                ),
              ],
            ),
            child: QrImageView(
              data: _myQRData!,
              version: QrVersions.auto,
              size: 280,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.H,
            ),
          ),
          SizedBox(height: 24),
          Text(
            'Show this QR to your contact',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SizedBox(height: 8),
          Text(
            'They can scan it to add you securely',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _startScanning,
            icon: Icon(Icons.qr_code_scanner),
            label: Text('Scan Their QR'),
          ),
          SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _myQRData!));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('QR data copied'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            icon: Icon(Icons.copy),
            label: Text('Copy QR Data'),
          ),
        ],
      ),
    );
  }
  
  Future<void> _startScanning() async {
    final result = await QRBarcodeScanner.showScannerDialog(
      context,
      title: 'Scan Contact QR',
      subtitle: 'Point camera at contact\'s QR code',
      primaryColor: Theme.of(context).colorScheme.primary,
      backgroundColor: Colors.black87,
      allowFlashToggle: true,
      allowCameraToggle: true,
      timeout: Duration(minutes: 2),
    );
    
    if (result != null) {
      _processScannedQR(result.code);
    }
  }
  
  void _processScannedQR(String qrData) {
    try {
      final contact = QRIntroduction.fromQRString(qrData);
      
      if (contact == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invalid QR code format'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        return;
      }
      
      if (!contact.isValid()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('QR code expired (older than 5 minutes)'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        return;
      }
      
      setState(() {
        _hasScanned = true;
        _scannedContact = contact;
      });
      
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to process QR code'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }
  
  Widget _buildContactConfirmation() {
    if (_scannedContact == null) {
      return Center(child: Text('No contact data'));
    }
    
    return Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.person_add,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            SizedBox(height: 24),
            Text(
              'Add Contact',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            SizedBox(height: 16),
            Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  children: [
                    CircleAvatar(
                      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                      radius: 30,
                      child: Text(
                        _scannedContact!.displayName[0].toUpperCase(),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    SizedBox(height: 12),
                    Text(
                      _scannedContact!.displayName,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    SizedBox(height: 8),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'Key: ${_scannedContact!.publicKey.substring(0, 16)}...',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 24),
            Text(
              'Adding this contact will enable end-to-end encrypted messaging',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _hasScanned = false;
                      _scannedContact = null;
                    });
                  },
                  child: Text('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: _saveScannedIntroduction,
                  icon: Icon(Icons.check),
                  label: Text('Add Contact'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Future<void> _saveScannedIntroduction() async {
  if (_scannedContact == null) return;
  
  try {
    final intro = _scannedContact!;
    
    if (!intro.isRecentlyGenerated(maxAgeMinutes: 30)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('QR code is too old (max 30 minutes)')),
        );
      }
      return;
    }
    
    await _storeIntroduction(intro);
    
    if (mounted) {
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Introduction saved! Connect via Bluetooth to chat with ${intro.displayName}'),
          duration: Duration(seconds: 3),
          backgroundColor: Colors.blue,
        ),
      );
    }
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to process QR: $e')),
      );
    }
  }
}

Future<void> _storeIntroduction(QRIntroduction intro) async {
  final prefs = await SharedPreferences.getInstance();
  final scannedAt = DateTime.now().millisecondsSinceEpoch;
  
  // Store "I met this person via QR"
  await prefs.setString('scanned_intro_${intro.publicKey}', jsonEncode({
    'intro_id': intro.introId,
    'their_public_key': intro.publicKey,
    'their_name': intro.displayName,
    'scanned_at': scannedAt,
    'qr_generated_at': intro.generatedAt,
    'status': 'introduction_only',
  }));

  // Logger('QRContactScreen').fine('👋 Stored introduction: ${intro.displayName} (${intro.introId})');
}

@override
void dispose() {
  // Mark when I stopped showing QR
  if (_myQRData != null) {
    _stopTrackingQRSession();
  }
  super.dispose();
}

}