import '../../../domain/interfaces/i_import_service.dart';
import '../../../domain/models/export_bundle.dart';
import 'import_service.dart';

/// Data-layer adapter exposing [ImportService] via domain contracts.
class ImportServiceAdapter implements IImportService {
  const ImportServiceAdapter();

  @override
  Future<ImportResult> importBundle({
    required String bundlePath,
    required String userPassphrase,
    bool clearExistingData = true,
  }) {
    return ImportService.importBundle(
      bundlePath: bundlePath,
      userPassphrase: userPassphrase,
      clearExistingData: clearExistingData,
    );
  }

  @override
  Future<Map<String, dynamic>> validateBundle({
    required String bundlePath,
    required String userPassphrase,
  }) {
    return ImportService.validateBundle(
      bundlePath: bundlePath,
      userPassphrase: userPassphrase,
    );
  }
}
