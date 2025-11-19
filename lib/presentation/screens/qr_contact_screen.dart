// File: lib/presentation/screens/qr_contact_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:qr_barcode_dialog_scanner/qr_barcode_dialog_scanner.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/ephemeral_discovery_hint.dart';
import '../../data/repositories/intro_hint_repository.dart';
import '../../data/repositories/user_preferences.dart';

class QRContactScreen extends ConsumerStatefulWidget {
  const QRContactScreen({super.key});

  @override
  ConsumerState<QRContactScreen> createState() => _QRContactScreenState();
}

class _QRContactScreenState extends ConsumerState<QRContactScreen> {
  String? _myQRData;
  EphemeralDiscoveryHint? _myHint;
  EphemeralDiscoveryHint? _scannedHint;
  bool _hasScanned = false;

  final _introHintRepo = IntroHintRepository();

  @override
  void initState() {
    super.initState();
    _generateMyQR();
  }

  Future<void> _generateMyQR() async {
    final userPrefs = UserPreferences();
    final displayName = await userPrefs.getUserName();

    // Generate ephemeral discovery hint (14-day validity)
    final hint = EphemeralDiscoveryHint.generate(
      displayName: displayName,
      validityPeriod: const Duration(days: 14),
    );

    // Save to repository
    await _introHintRepo.saveMyActiveHint(hint);

    setState(() {
      _myHint = hint;
      _myQRData = hint.toQRString();
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
              icon: const Icon(Icons.qr_code_scanner),
              tooltip: 'Scan QR',
            ),
        ],
      ),
      body: _hasScanned ? _buildContactConfirmation() : _buildQRDisplay(),
    );
  }

  Widget _buildQRDisplay() {
    if (_myQRData == null || _myHint == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final daysUntilExpiry = _myHint!.expiresAt
        .difference(DateTime.now())
        .inDays;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
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
            const SizedBox(height: 24),
            Text(
              'Show this QR to your contact',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Valid for $daysUntilExpiry days',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'They can scan and find you later',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _startScanning,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan Their QR'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _regenerateQR,
              icon: const Icon(Icons.refresh),
              label: const Text('Generate New QR'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _myQRData!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('QR data copied'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy QR Data'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _regenerateQR() async {
    setState(() {
      _myQRData = null;
      _myHint = null;
    });

    await _generateMyQR();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('New QR code generated'),
          duration: Duration(seconds: 2),
        ),
      );
    }
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
      timeout: const Duration(minutes: 2),
    );

    if (result != null) {
      _processScannedQR(result.code);
    }
  }

  void _processScannedQR(String qrData) {
    try {
      final hint = EphemeralDiscoveryHint.fromQRString(qrData);

      if (hint == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Invalid QR code format'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        return;
      }

      if (hint.isExpired) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('QR code expired - ask for a new one'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        return;
      }

      setState(() {
        _hasScanned = true;
        _scannedHint = hint;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to process QR code: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Widget _buildContactConfirmation() {
    if (_scannedHint == null) {
      return const Center(child: Text('No contact data'));
    }

    final daysUntilExpiry = _scannedHint!.expiresAt
        .difference(DateTime.now())
        .inDays;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.person_add,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              'Add Contact',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    CircleAvatar(
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.primaryContainer,
                      radius: 30,
                      child: Text(
                        (_scannedHint!.displayName ?? 'U')[0].toUpperCase(),
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _scannedHint!.displayName ?? 'Unknown',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'Hint: ${_scannedHint!.hintHex}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Valid for $daysUntilExpiry days',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Save this hint to find ${_scannedHint!.displayName ?? "this person"} nearby via Bluetooth',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'After pairing, you\'ll have secure end-to-end encrypted messaging',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _hasScanned = false;
                      _scannedHint = null;
                    });
                  },
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: _saveScannedHint,
                  icon: const Icon(Icons.check),
                  label: const Text('Save Hint'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveScannedHint() async {
    if (_scannedHint == null) return;

    try {
      // Save to repository
      await _introHintRepo.saveScannedHint(
        _scannedHint!.hintHex,
        _scannedHint!,
      );

      if (mounted) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Hint saved! Go to Discovery to find ${_scannedHint!.displayName ?? "this person"}',
            ),
            duration: const Duration(seconds: 4),
            backgroundColor: Colors.blue,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save hint: $e')));
      }
    }
  }

  @override
  void dispose() {
    // Clean up expired hints when leaving screen
    _introHintRepo.cleanupExpiredHints();
    super.dispose();
  }
}
