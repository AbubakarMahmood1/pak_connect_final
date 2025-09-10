enum PairingState {
  none,           // Not started
  displaying,     // Showing our code
  waiting,        // Waiting for other's code
  verifying,      // Checking codes
  completed,      // Successfully paired
  failed,         // Pairing failed
}

class PairingInfo {
  final String myCode;
  final String? theirCode;
  final PairingState state;
  final String? sharedSecret;
  
  const PairingInfo({
    required this.myCode,
    this.theirCode,
    required this.state,
    this.sharedSecret,
  });
  
  PairingInfo copyWith({
    String? theirCode,
    PairingState? state,
    String? sharedSecret,
  }) => PairingInfo(
    myCode: myCode,
    theirCode: theirCode ?? this.theirCode,
    state: state ?? this.state,
    sharedSecret: sharedSecret ?? this.sharedSecret,
  );
}