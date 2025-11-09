// Passphrase strength indicator widget
// Visual feedback for passphrase quality with color-coded strength meter

import 'package:flutter/material.dart';
import '../../../data/services/export_import/encryption_utils.dart';
import '../../../data/services/export_import/export_bundle.dart';

class PassphraseStrengthIndicator extends StatelessWidget {
  final String passphrase;
  final bool showWarnings;

  const PassphraseStrengthIndicator({
    super.key,
    required this.passphrase,
    this.showWarnings = true,
  });

  @override
  Widget build(BuildContext context) {
    if (passphrase.isEmpty) {
      return const SizedBox.shrink();
    }

    final validation = EncryptionUtils.validatePassphrase(passphrase);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),

        // Strength bar
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: validation.strength,
                  minHeight: 8,
                  backgroundColor: Colors.grey[300],
                  valueColor: AlwaysStoppedAnimation<Color>(
                    _getStrengthColor(validation),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _getStrengthLabel(validation),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: _getStrengthColor(validation),
              ),
            ),
          ],
        ),

        // Warnings
        if (showWarnings && validation.warnings.isNotEmpty) ...[
          const SizedBox(height: 8),
          ...validation.warnings.map(
            (warning) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    validation.isValid
                        ? Icons.info_outline
                        : Icons.warning_amber_rounded,
                    size: 16,
                    color: validation.isValid
                        ? Colors.blue[700]
                        : Colors.orange[700],
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      warning,
                      style: TextStyle(
                        fontSize: 12,
                        color: validation.isValid
                            ? Colors.blue[700]
                            : Colors.orange[700],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Color _getStrengthColor(PassphraseValidation validation) {
    if (!validation.isValid) {
      return Colors.red;
    }

    if (validation.isStrong) {
      return Colors.green;
    } else if (validation.isMedium) {
      return Colors.orange;
    } else {
      return Colors.yellow[700]!;
    }
  }

  String _getStrengthLabel(PassphraseValidation validation) {
    if (!validation.isValid) {
      return 'Too Weak';
    }

    if (validation.isStrong) {
      return 'Strong';
    } else if (validation.isMedium) {
      return 'Medium';
    } else {
      return 'Weak';
    }
  }
}
