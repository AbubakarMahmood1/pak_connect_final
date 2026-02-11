import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';

/// Implementation of IRepositoryProvider
///
/// Provides access to all Data layer repositories through a single abstraction.
/// Registered in DI container in service_locator.dart
///
/// **Purpose**: Decouple Core layer services from directly importing Data layer repositories.
/// Instead of: `import '../../data/repositories/contact_repository.dart'`
/// They receive: `IRepositoryProvider` via constructor injection
///
/// **Benefits**:
/// ✅ Follows dependency inversion principle (depend on abstractions, not concretions)
/// ✅ Simplifies testing (mock single provider instead of multiple repositories)
/// ✅ Centralizes repository access (easier to swap implementations)
/// ✅ Maintains strict layer boundaries (Core → does NOT import Data)
class RepositoryProviderImpl implements IRepositoryProvider {
  final IContactRepository _contactRepository;
  final IMessageRepository _messageRepository;

  RepositoryProviderImpl({
    required IContactRepository contactRepository,
    required IMessageRepository messageRepository,
  }) : _contactRepository = contactRepository,
       _messageRepository = messageRepository;

  @override
  IContactRepository get contactRepository => _contactRepository;

  @override
  IMessageRepository get messageRepository => _messageRepository;
}
