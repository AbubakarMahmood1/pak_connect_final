import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:qr_barcode_dialog_scanner/qr_barcode_dialog_scanner.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/qr_contact_data.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/user_preferences.dart';
import '../../core/services/simple_crypto.dart';

class QRContactScreen extends ConsumerStatefulWidget {
  @override
  ConsumerState<QRContactScreen> createState() => _QRContactScreenState();
}

class _QRContactScreenState extends ConsumerState<QRContactScreen> {
  String? _myQRData;
  QRContactData? _scannedContact;
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
    
    final contactData = QRContactData(
      publicKey: publicKey,
      displayName: displayName,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    
    setState(() {
      _myQRData = contactData.toQRString();
    });
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
                  color: Colors.black.withOpacity(0.1),
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
      final contact = QRContactData.fromQRString(qrData);
      
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
                      child: Text(
                        _scannedContact!.displayName[0].toUpperCase(),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      radius: 30,
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
                        color: Theme.of(context).colorScheme.surfaceVariant,
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
                  onPressed: _saveContact,
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
  
  Future<void> _saveContact() async {
    if (_scannedContact == null) return;
    
    try {
      // Check if already exists
      final contactRepo = ContactRepository();
      final existing = await contactRepo.getContact(_scannedContact!.publicKey);
      
      if (existing != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Contact already exists')),
        );
        Navigator.pop(context, false);
        return;
      }
      
      // Save as verified contact
      await contactRepo.saveContact(
        _scannedContact!.publicKey,
        _scannedContact!.displayName,
      );
      await contactRepo.markContactVerified(_scannedContact!.publicKey);
      
      // Compute and cache ECDH shared secret
      final sharedSecret = SimpleCrypto.computeSharedSecret(_scannedContact!.publicKey);
      if (sharedSecret != null) {
        await contactRepo.cacheSharedSecret(_scannedContact!.publicKey, sharedSecret);
        
        // Also restore it in SimpleCrypto for immediate use
        await SimpleCrypto.restoreConversationKey(
          _scannedContact!.publicKey, 
          sharedSecret
        );
      }
      
      if (mounted) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 8),
                Text('Contact added successfully!'),
              ],
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to add contact: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }
}