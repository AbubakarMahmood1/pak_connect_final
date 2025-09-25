# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

pak_connect is a secure peer-to-peer messaging Flutter application featuring mesh networking, end-to-end encryption, and advanced chat management. The app is currently in Phase 3 with UI-complete archive system features that require backend completion.

## Development Commands

### Setup & Dependencies
```bash
flutter pub get                    # Install dependencies
flutter pub get && dart run build_runner build --delete-conflicting-outputs  # Install deps + code generation
```

### Building & Running
```bash
flutter run                       # Run in debug mode
flutter run --release            # Run in release mode
flutter build apk                # Build Android APK
flutter build appbundle         # Build Android App Bundle
```

### Testing
```bash
flutter test                     # Run all tests
flutter test --coverage         # Run tests with coverage
flutter test test/specific_test.dart  # Run specific test file
flutter test integration_test/   # Run integration tests
```

### Code Quality
```bash
flutter analyze                  # Static analysis using analysis_options.yaml
dart format .                    # Format all Dart files
dart run build_runner build --delete-conflicting-outputs  # Code generation
```

## Architecture Overview

The codebase follows a clean architecture pattern with clear separation of concerns:

### Layer Structure
```
lib/
├── core/                 # Core business logic, utilities, and cross-cutting concerns
│   ├── messaging/       # Mesh networking, relay engine, offline queue
│   ├── security/        # Encryption, spam prevention, key management
│   ├── routing/         # Smart mesh routing algorithms
│   ├── power/          # Battery optimization and adaptive power management
│   ├── services/       # Core application services
│   └── models/         # Core data models and entities
├── domain/              # Business logic and domain services
│   ├── entities/       # Business entities (Message, Chat, Contact, etc.)
│   └── services/       # Domain services (ContactManagementService, etc.)
├── data/                # Data layer implementation
│   ├── repositories/   # Data access implementations
│   └── services/       # External service integrations (BLE, etc.)
└── presentation/        # UI layer
    ├── screens/        # Screen widgets
    ├── widgets/        # Reusable UI components
    ├── providers/      # Riverpod state management
    └── theme/          # App theming
```

## Key Components

### Mesh Networking Core
- `SmartMeshRouter`: Handles intelligent message routing across the mesh network
- `MeshRelayEngine`: Manages message relay and forwarding between devices
- `OfflineMessageQueue`: Queues messages for offline devices with automatic delivery

### Security System
- `MessageSecurity`: End-to-end encryption for all messages
- `EphemeralKeyManager`: Manages short-lived encryption keys
- `SpamPreventionManager`: Multi-layer spam filtering
- `ContactRecognizer`: Contact verification and trust management

### State Management
- Uses **Riverpod** as the primary state management solution
- Key providers in `presentation/providers/`
- State is managed through providers rather than traditional StatefulWidgets where possible

### Archive System (Phase 3 - UI Complete)
- Archive functionality is UI-complete but requires database migration
- Located in `domain/services/archive_*` and `presentation/screens/archive_*`
- Key files: `ArchiveManagementService`, `ArchiveScreen`, `ArchivedChatTile`

## Development Guidelines

### Code Style
- Follow the Flutter/Dart style guide enforced by `analysis_options.yaml`
- Use meaningful, descriptive names for classes and methods
- Prefer composition over inheritance
- Keep functions short and focused (aim for <20 lines)

### Testing Strategy
- Unit tests for business logic in `/test/`
- Widget tests for UI components
- Integration tests for complete user flows
- Extensive mesh networking tests for P2P communication validation

### Security Considerations
- All messages use end-to-end encryption
- Never log sensitive information (keys, message content)
- Use secure storage for persistent keys and user data
- Implement proper key rotation and ephemeral messaging

## Important Notes

### Current Development Phase
- **Phase 3**: Advanced chat management features (UI complete)
- **Pending**: Database migration for archive system persistence
- **Next**: Fuzzy search implementation and performance optimization

### Key Technologies
- **Flutter 3.35.3** with Dart 3.9.2
- **Riverpod** for state management
- **bluetooth_low_energy** for mesh networking
- **encrypt** and **pointycastle** for cryptography
- **flutter_secure_storage** for secure data persistence

### Testing Approach
The test suite includes comprehensive mesh networking integration tests, message routing validation, and relay system verification. Always run the full test suite before making changes to core networking or security components.

### Performance Considerations
- The app implements adaptive power management to optimize battery usage
- Message fragmentation handles large payloads efficiently
- Connection quality monitoring optimizes mesh routing decisions
- Background cache service minimizes repeated computations