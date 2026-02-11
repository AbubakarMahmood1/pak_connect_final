import '../models/export_bundle.dart';

/// Abstraction for validating and importing encrypted backup bundles.
abstract interface class IImportService {
  Future<ImportResult> importBundle({
    required String bundlePath,
    required String userPassphrase,
    bool clearExistingData,
  });

  Future<Map<String, dynamic>> validateBundle({
    required String bundlePath,
    required String userPassphrase,
  });
}
