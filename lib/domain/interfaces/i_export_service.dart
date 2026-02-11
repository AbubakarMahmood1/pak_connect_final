import '../models/export_bundle.dart';

/// Abstraction for creating and managing encrypted backup exports.
abstract interface class IExportService {
  Future<ExportResult> createExport({
    required String userPassphrase,
    String? customPath,
    ExportType exportType,
  });

  Future<String> getDefaultExportDirectory();

  Future<List<ExportBundle>> listAvailableExports();

  Future<int> cleanupOldExports({int keepCount});
}
