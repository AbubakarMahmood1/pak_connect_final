import '../../domain/interfaces/i_notification_handler.dart';
import '../../domain/interfaces/i_preferences_repository.dart';
import 'background_notification_handler_impl.dart';

INotificationHandler createPlatformBackgroundNotificationHandler({
  required IPreferencesRepository preferencesRepository,
}) => BackgroundNotificationHandlerImpl(
  preferencesRepository: preferencesRepository,
);
