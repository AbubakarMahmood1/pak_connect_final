enum PanicWipeOrigin { settings, hiddenAboutVersion }

class PanicWipeResult {
  PanicWipeResult({required this.success, List<String>? failures})
    : failures = List<String>.unmodifiable(failures ?? const <String>[]);

  final bool success;
  final List<String> failures;

  factory PanicWipeResult.failure(String failure) =>
      PanicWipeResult(success: false, failures: <String>[failure]);
}

abstract interface class IPanicWipeService {
  Future<PanicWipeResult> execute({required PanicWipeOrigin origin});
}
