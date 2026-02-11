import 'package:flutter/material.dart';

enum SecurityStatus {
  disconnected, // No connection
  connecting, // BLE connecting
  exchangingIdentity, // Getting names
  checkingContacts, // Validating contact status
  verifiedContact, // Mutual verified contacts (ECDH)
  asymmetricContact, // They have us, we don't have them
  needsPairing, // Connected but needs pairing
  paired, // Paired but not mutual contacts
  unknown, // Error or unsupported state
}

class SecurityState {
  final SecurityStatus status;
  final String? statusText;
  final String? actionText;
  final Color? statusColor;
  final IconData? statusIcon;
  final String? otherUserName;
  final String? otherPublicKey;
  final bool canSendMessages;
  final bool showContactAddButton;
  final bool showPairingButton;
  final bool showContactSyncButton;

  const SecurityState({
    required this.status,
    this.statusText,
    this.actionText,
    this.statusColor,
    this.statusIcon,
    this.otherUserName,
    this.otherPublicKey,
    required this.canSendMessages,
    required this.showContactAddButton,
    required this.showPairingButton,
    required this.showContactSyncButton,
  });

  factory SecurityState.disconnected() => SecurityState(
    status: SecurityStatus.disconnected,
    statusText: 'Disconnected',
    statusColor: Colors.red,
    statusIcon: Icons.bluetooth_disabled,
    canSendMessages: false,
    showContactAddButton: false,
    showPairingButton: false,
    showContactSyncButton: false,
  );

  factory SecurityState.connecting() => SecurityState(
    status: SecurityStatus.connecting,
    statusText: 'Connecting...',
    statusColor: Colors.orange,
    statusIcon: Icons.bluetooth_searching,
    canSendMessages: false,
    showContactAddButton: false,
    showPairingButton: false,
    showContactSyncButton: false,
  );

  factory SecurityState.exchangingIdentity() => SecurityState(
    status: SecurityStatus.exchangingIdentity,
    statusText: 'Exchanging identities...',
    statusColor: Colors.orange,
    statusIcon: Icons.sync,
    canSendMessages: false,
    showContactAddButton: false,
    showPairingButton: false,
    showContactSyncButton: false,
  );

  factory SecurityState.verifiedContact({
    required String otherUserName,
    required String otherPublicKey,
  }) => SecurityState(
    status: SecurityStatus.verifiedContact,
    statusText: 'Verified Contact • ECDH Encrypted',
    statusColor: Colors.green,
    statusIcon: Icons.verified_user,
    otherUserName: otherUserName,
    otherPublicKey: otherPublicKey,
    canSendMessages: true,
    showContactAddButton: false,
    showPairingButton: false,
    showContactSyncButton: false,
  );

  factory SecurityState.asymmetricContact({
    required String otherUserName,
    required String otherPublicKey,
  }) => SecurityState(
    status: SecurityStatus.asymmetricContact,
    statusText: 'Contact sync required',
    actionText: 'Add Contact',
    statusColor: Colors.orange,
    statusIcon: Icons.sync_problem,
    otherUserName: otherUserName,
    otherPublicKey: otherPublicKey,
    canSendMessages: true, // Can send with pairing key
    showContactAddButton: false,
    showPairingButton: false,
    showContactSyncButton: true,
  );

  factory SecurityState.paired({
    required String otherUserName,
    required String otherPublicKey,
  }) => SecurityState(
    status: SecurityStatus.paired,
    statusText: 'Secured • Tap + to add contact',
    actionText: 'Add Contact',
    statusColor: Colors.blue,
    statusIcon: Icons.lock,
    otherUserName: otherUserName,
    otherPublicKey: otherPublicKey,
    canSendMessages: true,
    showContactAddButton: true,
    showPairingButton: false,
    showContactSyncButton: false,
  );

  factory SecurityState.needsPairing({
    required String otherUserName,
    required String otherPublicKey,
  }) => SecurityState(
    status: SecurityStatus.needsPairing,
    statusText: 'Connected • Tap 🔓 to secure',
    actionText: 'Secure Chat',
    statusColor: Colors.orange,
    statusIcon: Icons.lock_open,
    otherUserName: otherUserName,
    otherPublicKey: otherPublicKey,
    canSendMessages: true,
    showContactAddButton: false,
    showPairingButton: true,
    showContactSyncButton: false,
  );
}
