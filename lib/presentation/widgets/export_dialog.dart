// Export dialog for creating encrypted data bundles
// Allows users to export all their data with passphrase protection

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../../data/services/export_import/export_service.dart';
import 'passphrase_strength_indicator.dart';

class ExportDialog extends StatefulWidget {
  const ExportDialog({super.key});

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  final _formKey = GlobalKey<FormState>();
  final _passphraseController = TextEditingController();
  final _confirmPassphraseController = TextEditingController();
  
  bool _obscurePassphrase = true;
  bool _obscureConfirm = true;
  bool _isExporting = false;
  String? _exportPath;
  String? _errorMessage;
  
  @override
  void dispose() {
    _passphraseController.dispose();
    _confirmPassphraseController.dispose();
    super.dispose();
  }
  
  Future<void> _performExport() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    
    setState(() {
      _isExporting = true;
      _errorMessage = null;
      _exportPath = null;
    });
    
    try {
      // Create export
      final result = await ExportService.createExport(
        userPassphrase: _passphraseController.text,
      );
      
      if (result.success && result.bundlePath != null) {
        setState(() {
          _exportPath = result.bundlePath;
        });
      } else {
        setState(() {
          _errorMessage = result.errorMessage ?? 'Export failed';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Export failed: $e';
      });
    } finally {
      setState(() {
        _isExporting = false;
      });
    }
  }
  
  Future<void> _shareExport() async {
    if (_exportPath == null) return;
    
    try {
      final file = File(_exportPath!);
      if (await file.exists()) {
        await Share.shareXFiles(
          [XFile(_exportPath!)],
          subject: 'PakConnect Backup',
          text: 'My encrypted PakConnect backup file',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to share: $e')),
        );
      }
    }
  }
  
  Future<void> _copyPathToClipboard() async {
    if (_exportPath == null) return;
    
    await Clipboard.setData(ClipboardData(text: _exportPath!));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Path copied to clipboard')),
      );
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.download_rounded),
          SizedBox(width: 12),
          Text('Export All Data'),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: _exportPath == null
              ? _buildExportForm(theme)
              : _buildSuccessView(theme),
        ),
      ),
      actions: _exportPath == null
          ? _buildExportActions()
          : _buildSuccessActions(),
    );
  }
  
  Widget _buildExportForm(ThemeData theme) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Warning message
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue[50],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue[200]!),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: Colors.blue[700], size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Choose a strong passphrase to encrypt your backup. '
                    'You\'ll need this passphrase to restore your data.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.blue[900],
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 20),
          
          // Passphrase field
          TextFormField(
            controller: _passphraseController,
            obscureText: _obscurePassphrase,
            decoration: InputDecoration(
              labelText: 'Passphrase',
              hintText: 'Enter strong passphrase',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassphrase ? Icons.visibility : Icons.visibility_off,
                ),
                onPressed: () {
                  setState(() {
                    _obscurePassphrase = !_obscurePassphrase;
                  });
                },
              ),
              border: const OutlineInputBorder(),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Passphrase is required';
              }
              return null;
            },
            onChanged: (value) {
              setState(() {}); // Rebuild to update strength indicator
            },
          ),
          
          // Strength indicator
          PassphraseStrengthIndicator(
            passphrase: _passphraseController.text,
          ),
          
          const SizedBox(height: 16),
          
          // Confirm passphrase field
          TextFormField(
            controller: _confirmPassphraseController,
            obscureText: _obscureConfirm,
            decoration: InputDecoration(
              labelText: 'Confirm Passphrase',
              hintText: 'Re-enter passphrase',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureConfirm ? Icons.visibility : Icons.visibility_off,
                ),
                onPressed: () {
                  setState(() {
                    _obscureConfirm = !_obscureConfirm;
                  });
                },
              ),
              border: const OutlineInputBorder(),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Please confirm your passphrase';
              }
              if (value != _passphraseController.text) {
                return 'Passphrases do not match';
              }
              return null;
            },
          ),
          
          // Error message
          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red[200]!),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, color: Colors.red[700], size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.red[900],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          
          // Progress indicator
          if (_isExporting) ...[
            const SizedBox(height: 16),
            const Center(
              child: Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Creating encrypted backup...'),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
  
  Widget _buildSuccessView(ThemeData theme) {
    final file = File(_exportPath!);
    final filename = file.uri.pathSegments.last;
    
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Success icon
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: Colors.green[100],
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.check_circle_rounded,
            color: Colors.green[700],
            size: 40,
          ),
        ),
        
        const SizedBox(height: 16),
        
        // Success message
        Text(
          'Backup Created Successfully!',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        
        const SizedBox(height: 8),
        
        Text(
          'Your data has been encrypted and saved.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: Colors.grey[600],
          ),
          textAlign: TextAlign.center,
        ),
        
        const SizedBox(height: 24),
        
        // File info
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey[100],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.file_present_rounded, color: Colors.grey[700]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      filename,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Location: ${file.parent.path}',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
        
        const SizedBox(height: 16),
        
        // Action buttons
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _copyPathToClipboard,
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy Path'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _shareExport,
                icon: const Icon(Icons.share_rounded, size: 18),
                label: const Text('Share'),
              ),
            ),
          ],
        ),
        
        const SizedBox(height: 12),
        
        // Important note
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.orange[50],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.orange[200]!),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange[700], size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Keep your passphrase safe! You cannot recover your backup without it.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.orange[900],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
  
  List<Widget> _buildExportActions() {
    return [
      TextButton(
        onPressed: _isExporting ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      ElevatedButton(
        onPressed: _isExporting ? null : _performExport,
        child: const Text('Create Backup'),
      ),
    ];
  }
  
  List<Widget> _buildSuccessActions() {
    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Done'),
      ),
    ];
  }
}
