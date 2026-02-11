import 'package:get_it/get_it.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';

/// Resolves the app-wide security service without exposing core implementation
/// details to data/presentation layers.
class SecurityServiceLocator {
  static ISecurityService? _fallback;

  static void registerFallback(ISecurityService service) {
    _fallback = service;
  }

  static ISecurityService get instance {
    final di = GetIt.instance;
    if (di.isRegistered<ISecurityService>()) {
      return di<ISecurityService>();
    }
    final fallback = _fallback;
    if (fallback != null) {
      return fallback;
    }
    throw StateError(
      'ISecurityService not registered. '
      'Register it in DI or call registerFallback().',
    );
  }
}
