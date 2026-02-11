import 'i_contact_repository.dart';
import 'i_message_repository.dart';

/// Interface for repository provider (dependency inversion for Core layer)
///
/// Instead of Core layer services directly importing from Data layer (violating layering),
/// they receive an IRepositoryProvider via DI that provides access to repositories.
///
/// **Pattern**: Repository Provider Pattern (reduces coupling, enables testing)
///
/// **Usage in Core services**:
/// ```dart
/// class SecurityManager {
///   final IRepositoryProvider _repositoryProvider;
///
///   SecurityManager(this._repositoryProvider);
///
///   Future<Contact?> getContact(String key) {
///     return _repositoryProvider.contactRepository.getContactByPublicKey(key);
///   }
/// }
/// ```
///
/// **Registration in DI**:
/// ```dart
/// getIt.registerSingleton<IRepositoryProvider>(
///   RepositoryProviderImpl(
///     contactRepository: getIt<IContactRepository>(),
///     messageRepository: getIt<IMessageRepository>(),
///     // ... others
///   ),
/// );
/// ```
abstract class IRepositoryProvider {
  /// Contact repository (CRUD for contact entities, security levels, trust status)
  IContactRepository get contactRepository;

  /// Message repository (CRUD for message entities, delivery status, encryption state)
  IMessageRepository get messageRepository;

  // NOTE: Additional repositories (PreferencesRepository, IntroHintRepository, etc.)
  // can be added to this interface as needed. This is the minimal set for Phase 3.
}
