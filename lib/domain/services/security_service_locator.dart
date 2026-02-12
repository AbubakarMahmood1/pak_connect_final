import 'package:pak_connect/domain/interfaces/i_security_service.dart';

/// Resolves the app-wide security service without exposing core implementation
/// details to data/presentation layers.
class SecurityServiceLocator {
  static ISecurityService Function()? _serviceResolver;

  static void configureServiceResolver(ISecurityService Function() resolver) {
    _serviceResolver = resolver;
  }

  static void clearServiceResolver() {
    _serviceResolver = null;
  }

  static ISecurityService get instance {
    final resolver = _serviceResolver;
    if (resolver != null) {
      return resolver();
    }
    throw StateError(
      'ISecurityService resolver not configured. '
      'Call SecurityServiceLocator.configureServiceResolver(...) during '
      'composition root setup.',
    );
  }
}
