import 'dart:async';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/models/pairing_state.dart';
import '../../core/services/security_manager.dart';
import '../../core/services/simple_crypto.dart';
import '../../data/repositories/contact_repository.dart';

/// Handles contact request initiation, acceptance, and finalization so
/// BLEStateManager can delegate mutual-consent flows.
class ContactRequestController {
  ContactRequestController({
    required Logger logger,
    required ContactRepository contactRepository,
    required Duration contactRequestTimeout,
    required Future<String> Function() myPersistentIdProvider,
    required String? Function() currentSessionIdProvider,
    required String? Function() otherUserNameProvider,
    required String? Function() myUserNameProvider,
    required Map<String, String> conversationKeys,
    required void Function(String publicKey) markBilateralSyncComplete,
  }) : _logger = logger,
       _contactRepository = contactRepository,
       _contactRequestTimeout = contactRequestTimeout,
       _getMyPersistentId = myPersistentIdProvider,
       _currentSessionId = currentSessionIdProvider,
       _otherUserName = otherUserNameProvider,
       _myUserName = myUserNameProvider,
       _conversationKeys = conversationKeys,
       _markBilateralSyncComplete = markBilateralSyncComplete;

  final Logger _logger;
  final ContactRepository _contactRepository;
  final Duration _contactRequestTimeout;
  final Future<String> Function() _getMyPersistentId;
  final String? Function() _currentSessionId;
  final String? Function() _otherUserName;
  final String? Function() _myUserName;
  final Map<String, String> _conversationKeys;
  final void Function(String publicKey) _markBilateralSyncComplete;

  bool _contactRequestPending = false;
  String? _pendingContactPublicKey;
  String? _pendingContactName;
  Completer<bool>? _contactRequestCompleter;

  final Map<String, Timer> _pendingOutgoingRequests = {};
  final Map<String, Completer<bool>> _outgoingRequestCompleters = {};

  Function(String, String)? onContactRequestReceived;
  Function(bool)? onContactRequestCompleted;
  Function(String, String)? onSendContactRequest;
  Function(String, String)? onSendContactAccept;
  Function()? onSendContactReject;

  bool get hasPendingRequest => _contactRequestPending;
  String? get pendingContactName => _pendingContactName;

  Future<bool> initiateContactRequest() async {
    final sessionId = _currentSessionId();
    final otherName = _otherUserName();

    if (sessionId == null || otherName == null) {
      _logger.warning('Cannot initiate contact request - missing device info');
      return false;
    }

    try {
      final myPublicKey = await _getMyPersistentId();
      final myName = _myUserName() ?? 'User';

      _logger.info('📱 CONTACT REQUEST: Initiating request to $otherName');

      final completer = Completer<bool>();
      _outgoingRequestCompleters[sessionId] = completer;

      final timer = Timer(_contactRequestTimeout, () {
        if (!completer.isCompleted) {
          _logger.warning('📱 CONTACT REQUEST: Timeout waiting for response');
          completer.complete(false);
        }
      });
      _pendingOutgoingRequests[sessionId] = timer;

      onSendContactRequest?.call(myPublicKey, myName);

      final accepted = await completer.future;
      _cleanupOutgoingRequest(sessionId);

      return accepted;
    } catch (e) {
      _logger.severe('Failed to initiate contact request: $e');
      return false;
    }
  }

  Future<bool> sendContactRequest() async {
    try {
      final myPublicKey = await _getMyPersistentId();
      final myName = _myUserName() ?? 'User';

      _logger.info('Sending contact request');
      onSendContactRequest?.call(myPublicKey, myName);

      _contactRequestCompleter = Completer<bool>();

      final accepted = await _contactRequestCompleter!.future.timeout(
        Duration(seconds: 30),
        onTimeout: () {
          _logger.warning('Contact request timeout');
          return false;
        },
      );

      return accepted;
    } catch (e) {
      _logger.severe('Failed to send contact request: $e');
      return false;
    }
  }

  void handleContactRequestAcceptResponse(
    String publicKey,
    String displayName,
  ) {
    _logger.info('📱 CONTACT REQUEST: Accepted by $displayName');

    final completer = _outgoingRequestCompleters[publicKey];
    if (completer != null && !completer.isCompleted) {
      completer.complete(true);
    }

    _finalizeContactAddition(publicKey, displayName, true);
  }

  void handleContactRequestRejectResponse() {
    final sessionId = _currentSessionId();
    final otherName = _otherUserName();

    if (sessionId != null) {
      _logger.info('📱 CONTACT REQUEST: Rejected by $otherName');

      final completer = _outgoingRequestCompleters[sessionId];
      if (completer != null && !completer.isCompleted) {
        completer.complete(false);
      }

      _cleanupOutgoingRequest(sessionId);
    }
  }

  Future<bool> get weHaveThemAsContact async {
    final sessionId = _currentSessionId();
    if (sessionId == null) return false;
    final contact = await _contactRepository.getContact(sessionId);
    return contact != null && contact.trustStatus == TrustStatus.verified;
  }

  Future<void> handleContactRequest(
    String publicKey,
    String displayName,
  ) async {
    _logger.info('📱 CONTACT REQUEST: Received from $displayName');

    final prefs = await SharedPreferences.getInstance();
    final allowNewContacts = prefs.getBool('allow_new_contacts') ?? true;

    if (!allowNewContacts) {
      _logger.info('📱 CONTACT REQUEST: Auto-rejected (new contacts disabled)');
      onSendContactReject?.call();
      return;
    }

    _contactRequestPending = true;
    _pendingContactPublicKey = publicKey;
    _pendingContactName = displayName;
    onContactRequestReceived?.call(publicKey, displayName);
  }

  Future<void> acceptContactRequest() async {
    if (!_contactRequestPending || _pendingContactPublicKey == null) {
      _logger.warning('No pending contact request');
      return;
    }

    try {
      _logger.info(
        '📱 MUTUAL CONSENT: Accepting contact request from $_pendingContactName',
      );

      final myPublicKey = await _getMyPersistentId();
      final myName = _myUserName() ?? 'User';
      onSendContactAccept?.call(myPublicKey, myName);

      await _finalizeContactAddition(
        _pendingContactPublicKey!,
        _pendingContactName!,
        true,
      );

      _contactRequestPending = false;
      _pendingContactPublicKey = null;
      _pendingContactName = null;
    } catch (e) {
      _logger.severe('Failed to accept contact request: $e');
      onContactRequestCompleted?.call(false);
    }
  }

  void rejectContactRequest() {
    if (!_contactRequestPending) return;

    onSendContactReject?.call();

    _contactRequestPending = false;
    _pendingContactPublicKey = null;
    _pendingContactName = null;

    onContactRequestCompleted?.call(false);
  }

  void handleContactAccept(String publicKey, String displayName) {
    _logger.info('📱 MUTUAL CONSENT: Contact request accepted by $displayName');
    handleContactRequestAcceptResponse(publicKey, displayName);
  }

  void _cleanupOutgoingRequest(String publicKey) {
    _pendingOutgoingRequests[publicKey]?.cancel();
    _pendingOutgoingRequests.remove(publicKey);
    _outgoingRequestCompleters.remove(publicKey);
  }

  Future<void> _finalizeContactAddition(
    String publicKey,
    String displayName,
    bool mutualConsent,
  ) async {
    try {
      _logger.info(
        '📱 FINALIZE: Adding contact with mutual consent: $displayName',
      );

      await _contactRepository.saveContactWithSecurity(
        publicKey,
        displayName,
        SecurityLevel.high,
      );
      await _contactRepository.markContactVerified(publicKey);

      final sharedSecret = SimpleCrypto.computeSharedSecret(publicKey);
      if (sharedSecret != null) {
        await _contactRepository.cacheSharedSecret(publicKey, sharedSecret);
        await SimpleCrypto.restoreConversationKey(publicKey, sharedSecret);
        _conversationKeys[publicKey] = sharedSecret;
        _logger.info('📱 FINALIZE: ECDH secret computed and cached');
      }

      _markBilateralSyncComplete(publicKey);
      onContactRequestCompleted?.call(true);
    } catch (e) {
      _logger.severe('Failed to finalize contact addition: $e');
      onContactRequestCompleted?.call(false);
    }
  }
}
