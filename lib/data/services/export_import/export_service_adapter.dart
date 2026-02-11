import '../../../domain/interfaces/i_export_service.dart';
import '../../../domain/models/export_bundle.dart';
import 'export_service.dart';

/// Data-layer adapter exposing [ExportService] via domain contracts.
class ExportServiceAdapter implements IExportService {
  const ExportServiceAdapter();

  @override
  Future<ExportResult> createExport({
    required String userPassphrase,
    String? customPath,
    ExportType exportType = ExportType.full,
  }) {
    return ExportService.createExport(
      userPassphrase: userPassphrase,
      customPath: customPath,
      exportType: exportType,
    );
  }

  @override
  Future<int> cleanupOldExports({int keepCount = 3}) {
    return ExportService.cleanupOldExports(keepCount: keepCount);
  }

  @override
  Future<String> getDefaultExportDirectory() {
    return ExportService.getDefaultExportDirectory();
  }

  @override
  Future<List<ExportBundle>> listAvailableExports() {
    return ExportService.listAvailableExports();
  }
}
