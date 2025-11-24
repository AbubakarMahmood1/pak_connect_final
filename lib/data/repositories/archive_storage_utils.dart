import 'package:logging/logging.dart';

/// Storage-focused helper for stats and timing
class ArchiveStorageUtils {
  final _logger = Logger('ArchiveStorageUtils');
  final Map<String, Duration> _operationTimes = {};
  int _operationsCount = 0;

  void recordOperationTime(String operation, Duration duration) {
    _operationTimes[operation] = duration;
    _operationsCount++;
    _logger.fine('Operation $operation took ${duration.inMilliseconds}ms');
  }

  Map<String, Duration> get operationTimes => _operationTimes;
  int get operationsCount => _operationsCount;
}
