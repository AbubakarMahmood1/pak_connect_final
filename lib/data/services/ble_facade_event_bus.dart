import 'package:logging/logging.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/spy_mode_info.dart';

class BleFacadeEventBus {
  BleFacadeEventBus({required Logger logger}) : _logger = logger;

  final Logger _logger;

  final Set<void Function(ConnectionInfo)> _connectionInfoListeners = {};
  final Set<void Function(String)> _hintMatchListeners = {};
  final Set<void Function(SpyModeInfo)> _spyModeListeners = {};
  final Set<void Function(String)> _identityListeners = {};

  Stream<ConnectionInfo> connectionInfoStream(ConnectionInfo currentInfo) {
    return Stream<ConnectionInfo>.multi((controller) {
      controller.add(currentInfo);

      void listener(ConnectionInfo info) {
        controller.add(info);
      }

      _connectionInfoListeners.add(listener);
      controller.onCancel = () {
        _connectionInfoListeners.remove(listener);
      };
    });
  }

  Stream<String> hintMatchesStream() {
    return Stream<String>.multi((controller) {
      void listener(String hint) {
        controller.add(hint);
      }

      _hintMatchListeners.add(listener);
      controller.onCancel = () {
        _hintMatchListeners.remove(listener);
      };
    });
  }

  Stream<SpyModeInfo> spyModeDetectedStream() {
    return Stream<SpyModeInfo>.multi((controller) {
      void listener(SpyModeInfo info) {
        controller.add(info);
      }

      _spyModeListeners.add(listener);
      controller.onCancel = () {
        _spyModeListeners.remove(listener);
      };
    });
  }

  Stream<String> identityRevealedStream() {
    return Stream<String>.multi((controller) {
      void listener(String identity) {
        controller.add(identity);
      }

      _identityListeners.add(listener);
      controller.onCancel = () {
        _identityListeners.remove(listener);
      };
    });
  }

  void emitConnectionInfo(ConnectionInfo info) {
    for (final listener in List.of(_connectionInfoListeners)) {
      try {
        listener(info);
      } catch (error, stackTrace) {
        _logger.warning(
          'Error notifying connection info listener: $error',
          error,
          stackTrace,
        );
      }
    }
  }

  void emitHintMatch(String hint) {
    for (final listener in List.of(_hintMatchListeners)) {
      try {
        listener(hint);
      } catch (error, stackTrace) {
        _logger.warning(
          'Error notifying hint listener: $error',
          error,
          stackTrace,
        );
      }
    }
  }

  void emitSpyMode(SpyModeInfo info) {
    for (final listener in List.of(_spyModeListeners)) {
      try {
        listener(info);
      } catch (error, stackTrace) {
        _logger.warning(
          'Error notifying spy mode listener: $error',
          error,
          stackTrace,
        );
      }
    }
  }

  void emitIdentityRevealed(String contactId) {
    for (final listener in List.of(_identityListeners)) {
      try {
        listener(contactId);
      } catch (error, stackTrace) {
        _logger.warning(
          'Error notifying identity listener: $error',
          error,
          stackTrace,
        );
      }
    }
  }

  void clear() {
    _connectionInfoListeners.clear();
    _hintMatchListeners.clear();
    _spyModeListeners.clear();
    _identityListeners.clear();
  }
}
