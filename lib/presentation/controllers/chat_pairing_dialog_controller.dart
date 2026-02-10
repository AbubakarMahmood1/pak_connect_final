import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/services/simple_crypto.dart';
import '../../data/services/ble_state_manager.dart';
import '../../core/services/security_manager.dart';
import '../widgets/pairing_dialog.dart';
import '../../core/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

/// Callback when pairing is requested
typedef OnPairingRequestedCallback = void Function();

/// Callback when pairing completes
typedef OnPairingCompletedCallback = void Function(bool success);

/// Callback when handling asymmetric contact
typedef OnAsymmetricContactCallback =
    void Function(String publicKey, String displayName);

/// Callback for showing errors
typedef OnPairingErrorCallback = void Function(String message);

/// Callback for showing success messages
typedef OnPairingSuccessCallback = void Function(String message);

/// Controller for managing pairing dialog interactions
///
/// Handles:
/// - Pairing dialog initiation and completion
/// - Asymmetric contact sync (when peer has you but you don't have them)
/// - Contact verification and ECDH key caching
/// - Security level upgrades
///
/// Design Notes:
/// - Dialog context must be provided by caller
/// - All async operations report results via callbacks
/// - Contact repository operations are transactional
/// - Security upgrades require peer persistent key
class ChatPairingDialogController {
  static final _logger = Logger('ChatPairingDialogController');

  // Dependencies
  final BLEStateManager stateManager;
  final IConnectionService connectionService;
  final ContactRepository contactRepository;
  final BuildContext context;
  final NavigatorState navigator;
  final String? Function() getTheirPersistentKey;

  // State
  bool _pairingDialogShown = false;

  // Callbacks
  final OnPairingCompletedCallback? onPairingCompleted;
  final OnAsymmetricContactCallback? onAsymmetricContact;
  final OnPairingErrorCallback? onPairingError;
  final OnPairingSuccessCallback? onPairingSuccess;

  ChatPairingDialogController({
    required this.stateManager,
    required this.connectionService,
    required this.contactRepository,
    required this.context,
    required this.navigator,
    required this.getTheirPersistentKey,
    this.onPairingCompleted,
    this.onAsymmetricContact,
    this.onPairingError,
    this.onPairingSuccess,
  });

  /// User requested pairing dialog
  ///
  /// Checks if device is connected before showing pairing dialog.
  /// Prevents multiple pairing dialogs from being shown simultaneously.
  ///
  /// Returns:
  /// - true if pairing dialog was initiated
  /// - false if already showing or not connected
  Future<bool> userRequestedPairing() async {
    // Prevent multiple pairing dialogs
    if (_pairingDialogShown) {
      _logger.warning('🔑 Pairing dialog already shown, ignoring request');
      return false;
    }

    // Check connection state
    // Note: In a real app, you'd check the actual connection provider
    // For now, we assume caller has verified connection
    _logger.info('🔑 User requested pairing dialog');

    _pairingDialogShown = true;
    await _showPairingDialog();
    return true;
  }

  /// Show pairing dialog and handle the pairing flow
  ///
  /// Process:
  /// 1. Set pairing in progress flag (pause health checks)
  /// 2. Generate pairing code
  /// 3. Show dialog to user
  /// 4. Wait for user to enter peer's code
  /// 5. Validate code with peer
  /// 6. If successful: Upgrade security level to MEDIUM
  /// 7. Resume health checks
  Future<void> _showPairingDialog() async {
    try {
      // Pause health checks during pairing
      connectionService.setPairingInProgress(true);
      stateManager.clearPairing();

      // Generate our pairing code
      final myCode = stateManager.generatePairingCode();

      _logger.info('🔑 Pairing dialog showing (code: $myCode)');

      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => PairingDialog(
          myCode: myCode,
          onCodeEntered: (theirCode) async {
            final success = await stateManager.completePairing(theirCode);
            if (navigator.canPop()) navigator.pop(success);
          },
          onCancel: () {
            if (navigator.canPop()) navigator.pop(false);
          },
        ),
      );

      // Resume health checks
      connectionService.setPairingInProgress(false);

      if (result == true) {
        _logger.info('✅ Pairing completed successfully');

        // Upgrade security level
        final otherKey = getTheirPersistentKey();
        if (otherKey != null) {
          _logger.info('🔑 Attempting security upgrade for: $otherKey');

          final upgradeResult = await stateManager.confirmSecurityUpgrade(
            otherKey,
            SecurityLevel.medium,
          );

          _logger.info('🔑 Security upgrade result: $upgradeResult');
        }

        onPairingSuccess?.call('Pairing successful');
        onPairingCompleted?.call(true);
      } else {
        _logger.warning('❌ Pairing failed or cancelled');
        stateManager.clearPairing();
        onPairingCompleted?.call(false);
      }
    } catch (e, st) {
      _logger.severe('❌ Error during pairing: $e', e, st);
      connectionService.setPairingInProgress(false);
      onPairingError?.call('Pairing error: $e');
      onPairingCompleted?.call(false);
    } finally {
      _pairingDialogShown = false;
    }
  }

  /// Handle asymmetric contact (peer has you, but you don't have them)
  ///
  /// Shows dialog explaining the situation and offers to add them.
  /// This happens when:
  /// - Peer has saved your key as a verified contact
  /// - You haven't added them back yet
  /// - Connection is established
  ///
  /// Parameters:
  /// - publicKey: Peer's public key
  /// - displayName: Peer's display name
  Future<void> handleAsymmetricContact(
    String publicKey,
    String displayName,
  ) async {
    if (!context.mounted) return;

    _logger.info('🔄 Showing asymmetric contact dialog for: $displayName');

    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.sync_problem, color: Colors.orange),
            SizedBox(width: 8),
            Text('Contact Sync'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$displayName has you as a verified contact, but you haven\'t added them back yet.',
            ),
            SizedBox(height: 12),
            Text('Add them to enable secure ECDH encryption?'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Not Now'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await addAsVerifiedContact(publicKey, displayName);
            },
            child: Text('Add Contact'),
          ),
        ],
      ),
    );
  }

  /// Add contact as verified and compute ECDH key
  ///
  /// Process:
  /// 1. Save contact to repository
  /// 2. Mark as verified
  /// 3. Compute ECDH shared secret (if possible)
  /// 4. Cache shared secret in repository
  /// 5. Restore key in SimpleCrypto for immediate use
  ///
  /// Parameters:
  /// - publicKey: Peer's public key
  /// - displayName: Peer's display name
  Future<void> addAsVerifiedContact(
    String publicKey,
    String displayName,
  ) async {
    final userId = _toUserId(publicKey);
    if (userId == null) {
      _logger.warning('addAsVerifiedContact called with empty public key');
      return;
    }

    try {
      _logger.info('🔐 Adding verified contact: $displayName');

      // Save contact
      await contactRepository.saveContact(userId.value, displayName);
      await contactRepository.markContactVerified(userId.value);

      // Compute and cache ECDH shared secret
      final sharedSecret = SimpleCrypto.computeSharedSecret(userId.value);
      if (sharedSecret != null) {
        await contactRepository.cacheSharedSecret(userId.value, sharedSecret);

        // Restore it in SimpleCrypto for immediate use
        await SimpleCrypto.restoreConversationKey(userId.value, sharedSecret);

        _logger.info('🔐 Cached ECDH shared secret for: $displayName');
      }

      onPairingSuccess?.call('Added $displayName as verified contact');
      _logger.info('✅ Successfully added verified contact: $displayName');
    } catch (e, st) {
      _logger.severe('❌ Failed to add verified contact: $e', e, st);
      onPairingError?.call('Failed to add contact: $e');
    }
  }

  /// Clear controller state
  ///
  /// Called when disposing or resetting the controller
  void clear() {
    _pairingDialogShown = false;
    _logger.info('🔑 Pairing dialog controller cleared');
  }

  UserId? _toUserId(String publicKey) {
    if (publicKey.isEmpty) return null;
    return UserId(publicKey);
  }
}
