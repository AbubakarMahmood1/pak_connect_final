/// Navigation operations needed by notification-tap flows.
///
/// Kept in domain so notification handlers never depend on concrete
/// navigation service implementations from lower-level infrastructure.
abstract class INotificationNavigationHandler {
  Future<void> navigateToChat({
    required String chatId,
    required String contactName,
    String? contactPublicKey,
  });

  Future<void> navigateToContactRequest({
    required String publicKey,
    required String contactName,
  });

  Future<void> navigateToHome();
}
