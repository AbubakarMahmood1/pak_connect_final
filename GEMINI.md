# Project: Pak Connect

## Project Overview

Pak Connect is a secure, peer-to-peer messaging application built with Flutter. It features end-to-end encryption, mesh networking for decentralized communication, and offline message queuing. The application is designed to be resilient and private, allowing users to communicate directly without relying on central servers. The architecture follows a clean, layered approach, separating core business logic, data handling, and UI presentation. Key technologies include Flutter for the cross-platform UI, Riverpod for state management, and various packages for Bluetooth LE communication, encryption, and local database storage.

## Building and Running

### Prerequisites
- Flutter SDK (3.0 or higher)
- Dart SDK (3.0 or higher)
- Android Studio / VS Code with Flutter extensions
- Android/iOS device or emulator

### Key Commands

*   **Install dependencies:**
    ```bash
    flutter pub get
    ```

*   **Run the app:**
    ```bash
    flutter run
    ```

*   **Run tests:**
    ```bash
    flutter test
    ```

*   **Run integration tests:**
    ```bash
    flutter test integration_test/
    ```

## Development Conventions

*   **State Management:** The project uses Riverpod for state management, with providers defined in the `presentation/providers` directory.
*   **Architecture:** The codebase is structured into `core`, `data`, `domain`, and `presentation` layers, promoting separation of concerns.
*   **Testing:** The project has a strong emphasis on testing, with unit, widget, and integration tests located in the `test` directory. The goal is to maintain high test coverage across the application.
*   **Code Style:** The project follows Dart and Flutter best practices, enforced by the `flutter_lints` package.
*   **Security:** Security is a core focus, with end-to-end encryption and secure key exchange implemented in the `core/security` module.
*   **Documentation:** The project includes comprehensive documentation in the root directory and within the `docs` folder, covering technical specifications, features, and architecture.