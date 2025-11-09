enum PairingState {
  none, // Not started
  pairingRequested, // We sent pairing request, waiting for accept
  waitingForAccept, // Pairing request sent, timeout running
  requestReceived, // They sent pairing request, showing accept/reject popup
  displaying, // Showing our PIN code
  waiting, // Waiting for other's code
  verifying, // Checking codes
  completed, // Successfully paired
  failed, // Pairing failed
  cancelled, // Pairing was cancelled by either device
}

class PairingInfo {
  final String myCode;
  final String? theirCode;
  final PairingState state;
  final String? sharedSecret;
  final String? theirEphemeralId; // Store ephemeral ID during pairing
  final String? theirDisplayName; // Store display name during pairing

  const PairingInfo({
    required this.myCode,
    this.theirCode,
    required this.state,
    this.sharedSecret,
    this.theirEphemeralId,
    this.theirDisplayName,
  });

  PairingInfo copyWith({
    String? theirCode,
    PairingState? state,
    String? sharedSecret,
    String? theirEphemeralId,
    String? theirDisplayName,
  }) => PairingInfo(
    myCode: myCode,
    theirCode: theirCode ?? this.theirCode,
    state: state ?? this.state,
    sharedSecret: sharedSecret ?? this.sharedSecret,
    theirEphemeralId: theirEphemeralId ?? this.theirEphemeralId,
    theirDisplayName: theirDisplayName ?? this.theirDisplayName,
  );
}
