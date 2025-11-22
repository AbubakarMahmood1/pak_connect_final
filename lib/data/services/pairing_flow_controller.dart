import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import '../../core/bluetooth/identity_session_state.dart';
import '../../core/models/pairing_state.dart';
import '../../core/models/protocol_message.dart';
import '../../core/models/spy_mode_info.dart';
import '../../core/services/security_manager.dart';
import '../../core/services/simple_crypto.dart';
import '../../core/security/ephemeral_key_manager.dart';
import '../../core/utils/string_extensions.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/intro_hint_repository.dart';
import '../../data/repositories/user_preferences.dart';
import 'chat_migration_service.dart';

/// Handles pairing flows, persistent key exchange, and security upgrades
/// so BLEStateManager can delegate.
class PairingFlowController {
  PairingFlowController({
    required Logger logger,
    required ContactRepository contactRepository,
    required IdentitySessionState identityState,
    required Map<String, String> conversationKeys,
    required Future<String> Function() myPersistentIdProvider,
    required String? Function() myUserNameProvider,
    required String? Function() otherUserNameProvider,
    required Future<void> Function({
      required String ephemeralId,
      required String persistentKey,
      String? contactName,
    })
    triggerChatMigration,
  }) : _logger = logger,
       _contactRepository = contactRepository,
       _identityState = identityState,
       _conversationKeys = conversationKeys,
       _getMyPersistentId = myPersistentIdProvider,
       _myUserName = myUserNameProvider,
       _otherUserName = otherUserNameProvider,
       _triggerChatMigration = triggerChatMigration;

  final Logger _logger;
  final ContactRepository _contactRepository;
  final IdentitySessionState _identityState;
  final Map<String, String> _conversationKeys;
  final Future<String> Function() _getMyPersistentId;
  final String? Function() _myUserName;
  final String? Function() _otherUserName;
  final Future<void> Function({
    required String ephemeralId,
    required String persistentKey,
    String? contactName,
  })
  _triggerChatMigration;

  // Pairing lifecycle state
  PairingInfo? _currentPairing;
  String? _theirReceivedCode;
  bool _weEnteredCode = false;
  String? _receivedPairingCode;
  Completer<bool>? _pairingCompleter;
  Timer? _pairingTimeout;

  // Callbacks
  Function(String)? onSendPairingCode;
  Function(String)? onSendPairingVerification;
  Function(ProtocolMessage)? onSendPairingRequest;
  Function(ProtocolMessage)? onSendPairingAccept;
  Function(ProtocolMessage)? onSendPairingCancel;
  Function(String ephemeralId, String displayName)? onPairingRequestReceived;
  Function()? onPairingCancelled;
  Function(ProtocolMessage)? onSendPersistentKeyExchange;
  Function(bool)? onContactRequestCompleted;
  Function(SpyModeInfo info)? onSpyModeDetected;

  // Accessors to identity state
  String? get _currentSessionId => _identityState.currentSessionId;
  set _currentSessionId(String? value) =>
      _identityState.currentSessionId = value;
  String? get _theirEphemeralId => _identityState.theirEphemeralId;
  set _theirEphemeralId(String? value) =>
      _identityState.theirEphemeralId = value;
  String? get _theirPersistentKey => _identityState.theirPersistentKey;
  set _theirPersistentKey(String? value) =>
      _identityState.theirPersistentKey = value;

  PairingInfo? get currentPairing => _currentPairing;
  bool get isPaired => _theirPersistentKey != null;

  String generatePairingCode() {
    if (_currentPairing != null &&
        _currentPairing!.state == PairingState.displaying) {
      _logger.info(
        'Returning existing pairing code: ${_currentPairing!.myCode}',
      );
      return _currentPairing!.myCode;
    }

    final random = Random();
    final code = (random.nextInt(9000) + 1000).toString();
    _currentPairing = PairingInfo(myCode: code, state: PairingState.displaying);

    // Reset for new pairing attempt
    _receivedPairingCode = null;
    _pairingCompleter = Completer<bool>();

    // Set timeout for pairing
    _pairingTimeout?.cancel();
    _pairingTimeout = Timer(Duration(seconds: 60), () {
      if (_pairingCompleter != null && !_pairingCompleter!.isCompleted) {
        _pairingCompleter!.complete(false);
        _logger.warning('Pairing timeout');
      }
    });

    _logger.info('Generated new pairing code: $code');
    return code;
  }

  Future<bool> completePairing(String theirCode) async {
    if (_currentPairing == null) {
      _logger.warning('No pairing in progress');
      return false;
    }

    _logger.info('User entered code: $theirCode');

    // Mark that we've entered their code
    _weEnteredCode = true;
    _receivedPairingCode = theirCode;

    _currentPairing = _currentPairing!.copyWith(
      theirCode: theirCode,
      state: PairingState.verifying,
    );

    try {
      _logger.info(
        'Sending our code to other device: ${_currentPairing!.myCode}',
      );
      onSendPairingCode?.call(_currentPairing!.myCode);

      if (_theirReceivedCode != null) {
        _logger.info('We already have their code, proceeding to verify');
        return await _performVerification();
      } else {
        _logger.info('Waiting for other device to send their code...');

        if (_pairingCompleter == null || _pairingCompleter!.isCompleted) {
          _pairingCompleter = Completer<bool>();
        }

        final success = await _pairingCompleter!.future.timeout(
          Duration(seconds: 60),
          onTimeout: () {
            _logger.warning('Timeout waiting for other device code');
            return false;
          },
        );
        print(
          '🔒 PAIRING DEBUG: Verification result - success=$success, sharedSecret=${_currentPairing?.sharedSecret?.shortId(8)}...',
        );
        return success;
      }
    } catch (e) {
      _logger.severe('Pairing failed: $e');
      _currentPairing = _currentPairing!.copyWith(state: PairingState.failed);
      return false;
    } finally {
      _pairingTimeout?.cancel();
    }
  }

  void handleReceivedPairingCode(String theirCode) {
    _logger.info('Received pairing code from other device: $theirCode');

    _theirReceivedCode = theirCode;

    if (!_weEnteredCode || _receivedPairingCode == null) {
      _logger.info('Storing their code, waiting for user to enter code');
      return;
    }

    if (theirCode != _receivedPairingCode) {
      _logger.severe(
        'CODE MISMATCH! We entered: $_receivedPairingCode, They sent: $theirCode',
      );
      _logger.severe('This means they entered wrong code!');
      _pairingCompleter?.complete(false);
      return;
    }

    _logger.info(
      'Codes match! Both devices entered correct codes. Starting verification...',
    );

    _performVerification().then((success) {
      if (_pairingCompleter != null && !_pairingCompleter!.isCompleted) {
        _pairingCompleter!.complete(success);
      }
    });
  }

  Future<void> handlePairingVerification(String theirSecretHash) async {
    _logger.info(
      'Received verification hash from other device: $theirSecretHash',
    );

    if (_currentPairing == null || _currentPairing!.sharedSecret == null) {
      _logger.warning(
        '⚠️ No shared secret available for verification - failing pairing for safety',
      );
      await _handleVerificationFailure('missing shared secret');
      return;
    }

    final ourHash = sha256
        .convert(utf8.encode(_currentPairing!.sharedSecret!))
        .toString()
        .shortId(8);
    if (ourHash == theirSecretHash) {
      _logger.info('✅ Verification hashes match - pairing confirmed!');
    } else {
      _logger.severe('❌ Hash mismatch - aborting pairing and revoking secrets');
      await _handleVerificationFailure('verification hash mismatch');
    }
  }

  /// Store the ephemeral ID received during handshake
  void setTheirEphemeralId(String ephemeralId, String displayName) {
    _logger.info('Storing their ephemeral ID: $ephemeralId ($displayName)');
    _identityState.setTheirEphemeralId(ephemeralId);
  }

  Future<void> _handleVerificationFailure(String reason) async {
    final contactId = _currentSessionId ?? _theirPersistentKey;
    final idsToClear = <String>{};
    if (contactId != null) idsToClear.add(contactId);
    if (_theirPersistentKey != null) idsToClear.add(_theirPersistentKey!);
    if (_currentSessionId != null) idsToClear.add(_currentSessionId!);

    if (_currentPairing != null) {
      _currentPairing = PairingInfo(
        myCode: _currentPairing!.myCode,
        theirCode: _currentPairing!.theirCode,
        state: PairingState.failed,
        sharedSecret: null,
        theirEphemeralId: _currentPairing!.theirEphemeralId,
        theirDisplayName: _currentPairing!.theirDisplayName,
      );
    }
    _pairingTimeout?.cancel();

    if (_pairingCompleter != null && !_pairingCompleter!.isCompleted) {
      _pairingCompleter!.complete(false);
    }

    for (final id in idsToClear) {
      _conversationKeys.remove(id);
      SimpleCrypto.clearConversationKey(id);
      await _contactRepository.clearCachedSecrets(id);
    }

    if (_theirPersistentKey != null) {
      SecurityManager.instance.unregisterIdentityMapping(_theirPersistentKey!);
      _theirPersistentKey = null;
    }

    if (contactId != null) {
      final contact = await _contactRepository.getContactByAnyId(contactId);
      if (contact != null && contact.securityLevel != SecurityLevel.low) {
        await _contactRepository.saveContactWithSecurity(
          contact.publicKey,
          contact.displayName,
          SecurityLevel.low,
          currentEphemeralId: contact.currentEphemeralId ?? contact.publicKey,
          persistentPublicKey: null,
        );
        _logger.info(
          '🔒 Reverted contact ${contact.publicKey.shortId()}... to LOW after verification failure ($reason)',
        );
      }
    }

    onPairingCancelled?.call();
  }

  Future<void> sendPairingRequest() async {
    if (_theirEphemeralId == null) {
      _logger.warning(
        '❌ Cannot send pairing request - no ephemeral ID (handshake incomplete)',
      );
      return;
    }

    final myEphId = EphemeralKeyManager.generateMyEphemeralKey();
    if (myEphId == null) {
      _logger.warning(
        '❌ Cannot send pairing request - my ephemeral ID not set',
      );
      return;
    }

    _logger.info(
      '📤 STEP 3: Sending pairing request to ${_otherUserName() ?? "Unknown"}',
    );

    final message = ProtocolMessage.pairingRequest(
      ephemeralId: myEphId,
      displayName: _myUserName() ?? 'User',
    );

    _currentPairing = PairingInfo(
      myCode: '',
      state: PairingState.pairingRequested,
      theirEphemeralId: _theirEphemeralId,
      theirDisplayName: _otherUserName(),
    );

    onSendPairingRequest?.call(message);

    _pairingTimeout?.cancel();
    _pairingTimeout = Timer(Duration(seconds: 30), () {
      if (_currentPairing?.state == PairingState.pairingRequested) {
        _logger.warning('⏰ Pairing request timeout - no response');
        _currentPairing = _currentPairing!.copyWith(state: PairingState.failed);
        onPairingCancelled?.call();
      }
    });

    _logger.info('✅ Pairing request sent, waiting for accept...');
  }

  void handlePairingRequest(ProtocolMessage message) {
    final theirEphemeralId = message.payload['ephemeralId'] as String;
    final displayName = message.payload['displayName'] as String;

    _logger.info('📥 STEP 3: Received pairing request from $displayName');
    _logger.info('   Their ephemeral ID: $theirEphemeralId');

    _theirEphemeralId ??= theirEphemeralId;

    if (_theirEphemeralId != theirEphemeralId) {
      _logger.warning(
        '⚠️ Ephemeral ID mismatch! Handshake: $_theirEphemeralId, Request: $theirEphemeralId',
      );
      _theirEphemeralId = theirEphemeralId;
    }

    _currentPairing = PairingInfo(
      myCode: '',
      state: PairingState.requestReceived,
      theirEphemeralId: theirEphemeralId,
      theirDisplayName: displayName,
    );

    _logger.info('🔔 Triggering pairing request popup for user');
    onPairingRequestReceived?.call(theirEphemeralId, displayName);
  }

  Future<void> acceptPairingRequest() async {
    if (_currentPairing?.state != PairingState.requestReceived) {
      _logger.warning('❌ No pending pairing request to accept');
      return;
    }

    final myEphId = EphemeralKeyManager.generateMyEphemeralKey();
    if (myEphId == null) {
      _logger.warning('❌ Cannot accept - my ephemeral ID not set');
      return;
    }

    _logger.info('✅ STEP 3: User accepted pairing request');

    final message = ProtocolMessage.pairingAccept(
      ephemeralId: myEphId,
      displayName: _myUserName() ?? 'User',
    );

    onSendPairingAccept?.call(message);

    final code = generatePairingCode();
    _logger.info('📱 Generated PIN code after accept: $code');

    _currentPairing = _currentPairing!.copyWith(state: PairingState.displaying);
  }

  Future<void> rejectPairingRequest() async {
    _logger.info('❌ STEP 3: User rejected pairing request');

    final message = ProtocolMessage.pairingCancel(
      reason: 'User rejected pairing',
    );
    onSendPairingCancel?.call(message);

    _currentPairing = null;
    _pairingTimeout?.cancel();
  }

  void handlePairingAccept(ProtocolMessage message) {
    final theirEphemeralId = message.payload['ephemeralId'] as String;
    final displayName = message.payload['displayName'] as String;

    _logger.info('📥 STEP 3: Received pairing accept from $displayName');

    if (_currentPairing?.state != PairingState.pairingRequested) {
      _logger.warning('⚠️ Received accept but we didn\'t send a request');
      return;
    }

    _pairingTimeout?.cancel();

    final code = generatePairingCode();
    _logger.info('📱 Generated PIN code after receiving accept: $code');

    _currentPairing = _currentPairing!.copyWith(
      state: PairingState.displaying,
      theirEphemeralId: theirEphemeralId,
      theirDisplayName: displayName,
    );

    _logger.info('✅ Pairing accepted, showing PIN dialog');
  }

  void handlePairingCancel(ProtocolMessage message) {
    final reason = message.payload['reason'] as String?;
    _logger.info(
      '❌ STEP 3: Pairing cancelled by other device${reason != null ? ": $reason" : ""}',
    );

    if (_theirPersistentKey != null) {
      SecurityManager.instance.unregisterIdentityMapping(_theirPersistentKey!);
      _logger.info(
        '🔐 Unregistered identity mapping due to pairing cancellation',
      );
    }

    _currentPairing = _currentPairing?.copyWith(state: PairingState.cancelled);
    _pairingTimeout?.cancel();

    onPairingCancelled?.call();

    Future.delayed(Duration(seconds: 1), () {
      _currentPairing = null;
    });
  }

  Future<void> cancelPairing({String? reason}) async {
    if (_currentPairing == null) {
      _logger.info('No active pairing to cancel');
      return;
    }

    _logger.info(
      '🚫 STEP 3: Cancelling pairing${reason != null ? ": $reason" : ""}',
    );

    if (_theirPersistentKey != null) {
      SecurityManager.instance.unregisterIdentityMapping(_theirPersistentKey!);
      _logger.info('🔐 Unregistered identity mapping due to user cancellation');
    }

    final message = ProtocolMessage.pairingCancel(
      reason: reason ?? 'User cancelled',
    );
    onSendPairingCancel?.call(message);

    _currentPairing = _currentPairing!.copyWith(state: PairingState.cancelled);
    _pairingTimeout?.cancel();

    Future.delayed(Duration(seconds: 1), () {
      _currentPairing = null;
    });
  }

  Future<void> ensureContactMaximumSecurity(String contactPublicKey) async {
    if (SimpleCrypto.hasConversationKey(contactPublicKey)) {
      _logger.info('✅ Contact already has maximum security (ECDH + Pairing)');
      return;
    }

    _logger.info(
      '🔐 Creating pairing key for contact to enable enhanced security',
    );

    final cachedSecret = await _contactRepository.getCachedSharedSecret(
      contactPublicKey,
    );
    if (cachedSecret != null) {
      final myId = await _getMyPersistentId();
      final conversationSeed = cachedSecret + myId + contactPublicKey;

      SimpleCrypto.initializeConversation(contactPublicKey, conversationSeed);
      _conversationKeys[contactPublicKey] = conversationSeed;

      _logger.info('✅ Enhanced security initialized for contact');
    }
  }

  Future<void> handlePersistentKeyExchange(String theirPersistentKey) async {
    if (_theirEphemeralId == null) {
      _logger.warning('❌ Cannot process persistent key - no ephemeral ID');
      return;
    }

    _identityState.setPersistentAssociation(
      persistentKey: theirPersistentKey,
      ephemeralId: _theirEphemeralId!,
    );

    SecurityManager.instance.registerIdentityMapping(
      persistentPublicKey: theirPersistentKey,
      ephemeralID: _theirEphemeralId!,
    );
    _logger.info(
      '🔐 Persistent key identity mapping registered: ${_truncateId(_theirEphemeralId!)} ↔ ${_truncateId(theirPersistentKey)}',
    );

    await _contactRepository.saveContactWithSecurity(
      _theirEphemeralId!,
      _otherUserName() ?? 'User',
      SecurityLevel.low,
      currentEphemeralId: _theirEphemeralId,
      persistentPublicKey: null,
    );

    final myPersistentKey = await _getMyPersistentId();
    final myEphId = EphemeralKeyManager.generateMyEphemeralKey();
    _logger.info('═══════════════════════════════════════════════════════════');
    _logger.info('🔑📊 HANDSHAKE COMPLETE: ${_otherUserName() ?? "Unknown"}');
    _logger.info(
      '🔑📊 My Keys:    Ephemeral=$myEphId | Persistent=${_truncateId(myPersistentKey)}',
    );
    _logger.info(
      '🔑📊 Their Keys: Ephemeral=$_theirEphemeralId | Persistent=${_truncateId(theirPersistentKey)}',
    );
    _logger.info('🔑📊 Security:   LOW (Noise session only - not paired yet)');
    _logger.info(
      '🔑📊 Contact ID: $_theirEphemeralId (ephemeral - will upgrade on pairing)',
    );
    _logger.info('═══════════════════════════════════════════════════════════');

    await _identityState.detectSpyMode(
      persistentKey: theirPersistentKey,
      getContactDisplayName: (pk) async {
        final contact = await _contactRepository.getContact(pk);
        return contact?.displayName;
      },
      hintsEnabledFetcher: () async {
        final userPrefs = UserPreferences();
        return userPrefs.getHintBroadcastEnabled();
      },
      onSpyModeDetected: onSpyModeDetected,
    );
  }

  Future<bool> confirmSecurityUpgrade(
    String publicKey,
    SecurityLevel newLevel,
  ) async {
    print(
      '[BLEStateManager] 🔧 DEBUG: confirmSecurityUpgrade called for ${_truncateId(publicKey)} to ${newLevel.name}',
    );

    try {
      final existingContact = await _contactRepository.getContact(publicKey);

      if (existingContact == null) {
        print(
          '[BLEStateManager] 🔧 DEBUG: No existing contact - creating new with ${newLevel.name} level',
        );
        await _contactRepository.saveContactWithSecurity(
          publicKey,
          'Unknown',
          newLevel,
        );
        onContactRequestCompleted?.call(true);
        return true;
      }

      print(
        '🔧 DEBUG: Current level: ${existingContact.securityLevel.name}, Target: ${newLevel.name}',
      );

      if (existingContact.securityLevel == SecurityLevel.high) {
        if (newLevel == SecurityLevel.medium) {
          print(
            '🔧 DEBUG: Contact already has ECDH (high security) - pairing unnecessary',
          );

          await _initializeCryptoForLevel(publicKey, SecurityLevel.high);

          onContactRequestCompleted?.call(true);
          return true;
        }
      }

      if (existingContact.securityLevel == newLevel) {
        print(
          '🔧 DEBUG: Already at ${newLevel.name} level - re-initializing crypto',
        );
        await _initializeCryptoForLevel(publicKey, newLevel);
        onContactRequestCompleted?.call(true);
        return true;
      }

      if (newLevel.index > existingContact.securityLevel.index) {
        print(
          '🔧 DEBUG: Valid upgrade from ${existingContact.securityLevel.name} to ${newLevel.name}',
        );
        final success = await _contactRepository.upgradeContactSecurity(
          publicKey,
          newLevel,
        );
        if (success) {
          await _initializeCryptoForLevel(publicKey, newLevel);
          onContactRequestCompleted?.call(true);
        }
        return success;
      } else {
        print('🔧 DEBUG: Invalid downgrade attempt blocked');
        onContactRequestCompleted?.call(true);
        return false;
      }
    } catch (e) {
      print('🔧 DEBUG: confirmSecurityUpgrade failed: $e');
      return false;
    }
  }

  Future<bool> resetContactSecurity(String publicKey, String reason) async {
    print('🔧 SECURITY RESET: Resetting $publicKey due to: $reason');

    try {
      final success = await _contactRepository.resetContactSecurity(
        publicKey,
        reason,
      );

      if (success) {
        SimpleCrypto.clearConversationKey(publicKey);
        onContactRequestCompleted?.call(true);
      }

      return success;
    } catch (e) {
      print('🔧 SECURITY RESET FAILED: $e');
      return false;
    }
  }

  Future<void> handleSecurityLevelSync(Map<String, dynamic> payload) async {
    final theirSecurityLevel =
        SecurityLevel.values[payload['securityLevel'] as int];

    print('🔒 SECURITY SYNC: They have us at ${theirSecurityLevel.name} level');

    if (_currentSessionId != null) {
      final ourSecurityLevel = await _contactRepository.getContactSecurityLevel(
        _currentSessionId!,
      );

      print('🔒 SECURITY SYNC: We have them at ${ourSecurityLevel.name} level');

      final mutualLevel = ourSecurityLevel.index < theirSecurityLevel.index
          ? ourSecurityLevel
          : theirSecurityLevel;

      print('🔒 SECURITY SYNC: Mutual level determined: ${mutualLevel.name}');

      if (ourSecurityLevel != mutualLevel) {
        await _contactRepository.updateContactSecurityLevel(
          _currentSessionId!,
          mutualLevel,
        );
        print(
          '🔒 SECURITY SYNC: Updated our level to match mutual: ${mutualLevel.name}',
        );

        onContactRequestCompleted?.call(true);
      }
    }
  }

  void clearPairing() {
    _currentPairing = null;
    _receivedPairingCode = null;
    _theirReceivedCode = null;
    _weEnteredCode = false;
    _pairingCompleter = null;
    _pairingTimeout?.cancel();
    _logger.info('Pairing state cleared');
  }

  Future<bool> _performVerification() async {
    if (_currentPairing == null ||
        _receivedPairingCode == null ||
        _theirReceivedCode == null) {
      _logger.warning('Missing data for verification');
      return false;
    }

    try {
      String myIdForSecret;
      try {
        myIdForSecret = _theirPersistentKey != null
            ? await _getMyPersistentId()
            : EphemeralKeyManager.generateMyEphemeralKey();
      } catch (e) {
        _logger.warning('Falling back to persistent ID for pairing secret: $e');
        myIdForSecret = await _getMyPersistentId();
      }

      final theirIdForSecret =
          _theirPersistentKey ?? _theirEphemeralId ?? _currentSessionId;

      if (theirIdForSecret == null) {
        _logger.warning('No other device public key');
        return false;
      }

      final sortedCodes = [_currentPairing!.myCode, _receivedPairingCode!]
        ..sort();
      final sortedKeys = [myIdForSecret, theirIdForSecret]..sort();

      final combinedData =
          '${sortedCodes[0]}:${sortedCodes[1]}:${sortedKeys[0]}:${sortedKeys[1]}';
      final sharedSecret = sha256.convert(utf8.encode(combinedData)).toString();

      _logger.info('Computed shared secret from codes');
      await _ensureContactExistsAfterHandshake(
        _currentSessionId ?? theirIdForSecret,
        _otherUserName() ?? 'User',
      );

      final secretHash = sha256
          .convert(utf8.encode(sharedSecret))
          .toString()
          .shortId(8);
      _logger.info('Sending verification hash: $secretHash');
      await onSendPairingVerification?.call(secretHash);

      _conversationKeys[theirIdForSecret] = sharedSecret;
      if (_currentSessionId != null && _currentSessionId != theirIdForSecret) {
        _conversationKeys[_currentSessionId!] = sharedSecret;
      }
      await _contactRepository.cacheSharedSecret(
        theirIdForSecret,
        sharedSecret,
      );
      if (_currentSessionId != null && _currentSessionId != theirIdForSecret) {
        await _contactRepository.cacheSharedSecret(
          _currentSessionId!,
          sharedSecret,
        );
      }

      _currentPairing = _currentPairing!.copyWith(
        state: PairingState.completed,
        sharedSecret: sharedSecret,
      );

      _logger.info('✅ Pairing completed successfully!');

      SimpleCrypto.initializeConversation(theirIdForSecret, sharedSecret);
      if (_currentSessionId != null && _currentSessionId != theirIdForSecret) {
        SimpleCrypto.initializeConversation(_currentSessionId!, sharedSecret);
      }

      if (_theirEphemeralId != null && _theirPersistentKey != null) {
        _logger.info('🔐 Upgrading contact from LOW to MEDIUM security');

        final contact = await _contactRepository.getContact(_theirEphemeralId!);

        if (contact != null) {
          await _contactRepository.saveContactWithSecurity(
            contact.publicKey,
            contact.displayName,
            SecurityLevel.medium,
            currentEphemeralId: contact.currentEphemeralId,
            persistentPublicKey: _theirPersistentKey!,
          );

          _logger.info('✅ Contact upgraded to MEDIUM');
          _logger.info(
            '   publicKey (unchanged): ${contact.publicKey.shortId()}...',
          );
          _logger.info(
            '   persistentPublicKey (now set): ${_theirPersistentKey!.shortId()}...',
          );

          SecurityManager.instance.registerIdentityMapping(
            persistentPublicKey: _theirPersistentKey!,
            ephemeralID: _theirEphemeralId!,
          );
          _logger.info(
            '🔑 Registered Noise identity mapping: ${_theirPersistentKey!.shortId(8)}... → ${_theirEphemeralId!.shortId(8)}...',
          );

          await _triggerChatMigration(
            ephemeralId: contact.publicKey,
            persistentKey: _theirPersistentKey!,
            contactName: _otherUserName(),
          );
        } else {
          _logger.warning('⚠️ Cannot upgrade - contact not found');
        }
      }

      await _exchangePersistentKeys();

      return true;
    } catch (e) {
      _logger.severe('Verification failed: $e');
      _currentPairing = _currentPairing!.copyWith(state: PairingState.failed);

      if (_theirPersistentKey != null) {
        SecurityManager.instance.unregisterIdentityMapping(
          _theirPersistentKey!,
        );
        _logger.info(
          '🔐 Unregistered identity mapping due to verification failure',
        );
      }

      return false;
    }
  }

  Future<void> _exchangePersistentKeys() async {
    final myPersistentKey = await _getMyPersistentId();

    if (_theirEphemeralId == null) {
      _logger.warning('❌ Cannot exchange persistent keys - no ephemeral ID');
      return;
    }

    final myEphId = EphemeralKeyManager.generateMyEphemeralKey();
    _logger.info(
      '🔑 STEP 4: Exchanging persistent keys (my ephemeral: $myEphId)',
    );

    final message = ProtocolMessage.persistentKeyExchange(
      persistentPublicKey: myPersistentKey,
    );

    onSendPersistentKeyExchange?.call(message);
    _logger.info('📤 STEP 4: Sent my persistent public key');
  }

  Future<void> _ensureContactExistsAfterHandshake(
    String publicKey,
    String displayName, {
    String? ephemeralId,
  }) async {
    final existingContact = await _contactRepository.getContact(publicKey);

    if (existingContact == null) {
      await _contactRepository.saveContactWithSecurity(
        publicKey,
        displayName,
        SecurityLevel.low,
        currentEphemeralId: ephemeralId,
      );
      _logger.info(
        '🔒 HANDSHAKE: Created contact with LOW security (Noise session): $displayName',
      );

      await _deleteIntroHintAfterConnection(displayName, publicKey);
    } else {
      if (existingContact.securityLevel.index < SecurityLevel.low.index) {
        await _contactRepository.updateContactSecurityLevel(
          publicKey,
          SecurityLevel.low,
        );
        _logger.info(
          '🔒 HANDSHAKE: Updated contact to LOW security (Noise session): $displayName',
        );
      }
      if (ephemeralId != null) {
        await _contactRepository.updateContactEphemeralId(
          publicKey,
          ephemeralId,
        );
        _logger.info(
          '🔒 HANDSHAKE: Updated ephemeral ID for contact: $displayName',
        );
      }
    }
  }

  Future<void> _deleteIntroHintAfterConnection(
    String displayName,
    String publicKey,
  ) async {
    try {
      final introHintRepo = IntroHintRepository();
      final scannedHints = await introHintRepo.getScannedHints();

      for (final hint in scannedHints.values) {
        if (hint.displayName == displayName) {
          await introHintRepo.removeScannedHint(hint.hintHex);
          _logger.info(
            '🗑️ PRIVACY: Deleted intro hint after connection: ${hint.hintHex} ($displayName)',
          );
          _logger.info(
            '   Reason: Intro hints are temporary - prevents identity linkage across sessions',
          );
          return;
        }
      }

      _logger.fine(
        'ℹ️ No intro hint found to delete for $displayName (may not be QR-based connection)',
      );
    } catch (e, stackTrace) {
      _logger.warning('⚠️ Failed to delete intro hint for $displayName: $e');
      _logger.fine('Stack trace: $stackTrace');
    }
  }

  Future<void> _initializeCryptoForLevel(
    String publicKey,
    SecurityLevel level,
  ) async {
    switch (level) {
      case SecurityLevel.medium:
        if (!SimpleCrypto.hasConversationKey(publicKey)) {
          final secret = _conversationKeys[publicKey];
          if (secret != null) {
            SimpleCrypto.initializeConversation(publicKey, secret);
          }
        }
        break;

      case SecurityLevel.high:
        final sharedSecret = SimpleCrypto.computeSharedSecret(publicKey);
        if (sharedSecret != null) {
          await _contactRepository.cacheSharedSecret(publicKey, sharedSecret);
          await SimpleCrypto.restoreConversationKey(publicKey, sharedSecret);
        }
        break;

      case SecurityLevel.low:
        break;
    }
  }

  String _truncateId(String? id, {int maxLength = 16}) {
    if (id == null) return 'null';
    if (id.length <= maxLength) return id;
    return '${id.substring(0, maxLength)}...';
  }
}
