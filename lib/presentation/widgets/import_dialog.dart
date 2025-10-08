// Import dialog for restoring encrypted data bundles
// Allows users to import backups from .pakconnect files

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../../data/services/export_import/import_service.dart';

class ImportDialog extends StatefulWidget {
  const ImportDialog({super.key});

  @override
  State<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<ImportDialog> {
  final _passphraseController = TextEditingController();
  
  String? _selectedFilePath;
  bool _obscurePassphrase = true;
  bool _isValidating = false;
  bool _isImporting = false;
  Map<String, dynamic>? _bundleInfo;
  String? _errorMessage;
  bool _importComplete = false;
  int? _recordsRestored;
  
  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }
  
  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pakconnect'],
        dialogTitle: 'Select PakConnect Backup',
      );
      
      if (result != null && result.files.single.path != null) {
        setState(() {
          _selectedFilePath = result.files.single.path;
          _bundleInfo = null;
          _errorMessage = null;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to select file: $e';
      });
    }
  }
  
  Future<void> _validateBundle() async {
    if (_selectedFilePath == null || _passphraseController.text.isEmpty) {
      return;
    }
    
    setState(() {
      _isValidating = true;
      _errorMessage = null;
      _bundleInfo = null;
    });
    
    try {
      final validation = await ImportService.validateBundle(
        bundlePath: _selectedFilePath!,
        userPassphrase: _passphraseController.text,
      );
      
      if (validation['valid'] == true) {
        setState(() {
          _bundleInfo = validation;
        });
      } else {
        setState(() {
          _errorMessage = validation['error'] ?? 'Validation failed';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Validation failed: $e';
      });
    } finally {
      setState(() {
        _isValidating = false;
      });
    }
  }
  
  Future<void> _performImport() async {
    if (_selectedFilePath == null || _passphraseController.text.isEmpty) {
      return;
    }
    
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            SizedBox(width: 12),
            Text('Confirm Import'),
          ],
        ),
        content: const Text(
          'This will REPLACE all your current data with the backup. '
          'This action cannot be undone.\n\n'
          'Are you sure you want to continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
            ),
            child: const Text('Import Anyway'),
          ),
        ],
      ),
    );
    
    if (confirmed != true) return;
    
    setState(() {
      _isImporting = true;
      _errorMessage = null;
    });
    
    try {
      final result = await ImportService.importBundle(
        bundlePath: _selectedFilePath!,
        userPassphrase: _passphraseController.text,
        clearExistingData: true,
      );
      
      if (result.success) {
        setState(() {
          _importComplete = true;
          _recordsRestored = result.recordsRestored;
        });
      } else {
        setState(() {
          _errorMessage = result.errorMessage ?? 'Import failed';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Import failed: $e';
      });
    } finally {
      setState(() {
        _isImporting = false;
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.upload_file_rounded),
          SizedBox(width: 12),
          Text('Import Backup'),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: _importComplete
              ? _buildSuccessView(theme)
              : _buildImportForm(theme),
        ),
      ),
      actions: _importComplete
          ? _buildSuccessActions()
          : _buildImportActions(),
    );
  }
  
  Widget _buildImportForm(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Warning message
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
                  'Importing will replace all your current data. '
                  'Make sure you have the correct backup file.',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.orange[900],
                  ),
                ),
              ),
            ],
          ),
        ),
        
        const SizedBox(height: 20),
        
        // File selection
        OutlinedButton.icon(
          onPressed: _isValidating || _isImporting ? null : _pickFile,
          icon: const Icon(Icons.folder_open_rounded),
          label: Text(_selectedFilePath == null
              ? 'Select Backup File'
              : 'Change File'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(double.infinity, 48),
          ),
        ),
        
        if (_selectedFilePath != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.file_present_rounded, color: Colors.grey[700]),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    File(_selectedFilePath!).uri.pathSegments.last,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
        
        const SizedBox(height: 16),
        
        // Passphrase field
        TextField(
          controller: _passphraseController,
          obscureText: _obscurePassphrase,
          enabled: !_isValidating && !_isImporting,
          decoration: InputDecoration(
            labelText: 'Passphrase',
            hintText: 'Enter backup passphrase',
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
          onChanged: (value) {
            if (_bundleInfo != null) {
              setState(() {
                _bundleInfo = null; // Clear validation when passphrase changes
              });
            }
          },
          onSubmitted: (_) => _validateBundle(),
        ),
        
        const SizedBox(height: 12),
        
        // Validate button
        if (_selectedFilePath != null && _bundleInfo == null)
          ElevatedButton.icon(
            onPressed: _isValidating || _isImporting || _passphraseController.text.isEmpty
                ? null
                : _validateBundle,
            icon: const Icon(Icons.verified_user_rounded, size: 18),
            label: const Text('Validate Backup'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 40),
            ),
          ),
        
        // Bundle info (after validation)
        if (_bundleInfo != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.green[50],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green[200]!),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.check_circle_rounded, color: Colors.green[700], size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Backup Validated',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.green[900],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildInfoRow('Username', _bundleInfo!['username'] ?? 'Unknown'),
                _buildInfoRow('Device ID', _bundleInfo!['device_id'] ?? 'Unknown'),
                _buildInfoRow('Date', _formatTimestamp(_bundleInfo!['timestamp'])),
                _buildInfoRow('Records', '${_bundleInfo!['total_records'] ?? 0}'),
              ],
            ),
          ),
        ],
        
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
        if (_isValidating || _isImporting) ...[
          const SizedBox(height: 16),
          Center(
            child: Column(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                Text(_isValidating
                    ? 'Validating backup...'
                    : 'Importing data...'),
              ],
            ),
          ),
        ],
      ],
    );
  }
  
  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '$label:',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
  
  String _formatTimestamp(dynamic timestamp) {
    if (timestamp == null) return 'Unknown';
    try {
      final date = DateTime.parse(timestamp.toString());
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
             '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return timestamp.toString();
    }
  }
  
  Widget _buildSuccessView(ThemeData theme) {
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
          'Import Successful!',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        
        const SizedBox(height: 8),
        
        Text(
          'Your data has been restored.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: Colors.grey[600],
          ),
          textAlign: TextAlign.center,
        ),
        
        const SizedBox(height: 24),
        
        // Stats
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey[100],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              Text(
                '$_recordsRestored',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: theme.primaryColor,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Records Restored',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
        ),
        
        const SizedBox(height: 16),
        
        // Info note
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
                  'Please restart the app to ensure all data is properly loaded.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.blue[900],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
  
  List<Widget> _buildImportActions() {
    return [
      TextButton(
        onPressed: _isValidating || _isImporting
            ? null
            : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      ElevatedButton(
        onPressed: _bundleInfo != null && !_isValidating && !_isImporting
            ? _performImport
            : null,
        child: const Text('Import Data'),
      ),
    ];
  }
  
  List<Widget> _buildSuccessActions() {
    return [
      ElevatedButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('Done'),
      ),
    ];
  }
}
