# Project: PakConnect

## 1. Project Overview
PakConnect is a secure, decentralized, peer-to-peer messaging application built with Flutter. It leverages **BLE Mesh Networking** for off-grid communication and the **Noise Protocol Framework** (XX/KK patterns) for military-grade end-to-end encryption. The app is designed to function without central servers, relying on a smart relay mesh to deliver messages across devices.

**Key Features:**
*   **Decentralized Mesh**: Multi-hop messaging via smart relays (max 3-5 hops) using custom routing algorithms.
*   **Security**: Noise Protocol (X25519 + ChaCha20-Poly1305), SQLCipher encrypted local storage.
*   **Identity**: Sophisticated dual-layer identity system (Immutable Public Key + Rotatable Ephemeral IDs) to preserve privacy.
*   **Architecture**: Strict Clean Layered Architecture (Presentation, Domain, Core, Data).

## 2. Tech Stack & Environment
*   **Framework**: Flutter 3.9+ / Dart 3.9+
*   **State Management**: Riverpod 3.0 (using `riverpod_generator` and functional provider patterns).
*   **Database**: SQLite (`sqflite`) with SQLCipher encryption. Schema Version: 9.
*   **Cryptography**: 
    *   `pinenacl`: X25519 Diffie-Hellman.
    *   `cryptography`: ChaCha20-Poly1305 AEAD.
    *   `pointycastle`: Auxiliary primitives.
*   **BLE**: `bluetooth_low_energy` (operating in Dual-role: Central + Peripheral simultaneously).

## 3. Critical Invariants (DO NOT VIOLATE)
See `AGENTS.md` for the complete list of inviolable rules.
*   **Identity**:
    *   `Contact.publicKey` is **IMMUTABLE** and serves as the primary database key.
    *   `Contact.persistentPublicKey` is nullable and used for "friend" verification (Medium+ security).
    *   `Contact.currentEphemeralId` rotates per connection/session.
*   **Security**:
    *   **NO** encryption/decryption is permitted before the Noise Handshake state reaches `established`.
    *   Nonces must be sequential; gaps trigger replay protection.
*   **Mesh**:
    *   Message IDs must be deterministic: `SHA-256(timestamp + senderKey + content)`.
    *   Duplicate detection window is **5 minutes** (enforced by `SeenMessageStore`).
    *   Relays must attempt local delivery **before** forwarding.

## 4. Architecture & Key Paths
*   **Presentation** (`lib/presentation/`): Riverpod providers, Screens, Widgets.
*   **Domain** (`lib/domain/`): Pure business logic, Use Cases, Repository Interfaces.
*   **Core** (`lib/core/`): Infrastructure, BLE stack, Security implementation, Mesh Engine.
    *   `lib/core/messaging/mesh_relay_engine.dart`: Core relay logic and duplicate detection.
    *   `lib/core/security/noise/`: Noise protocol implementation (Handle with extreme care).
    *   `lib/core/bluetooth/`: BLE handshake coordination and state machine.
*   **Data** (`lib/data/`): Repositories, DTOs, Datasources.
    *   `lib/data/database/database_helper.dart`: SQLCipher setup, Schema definitions, and Migrations.

## 5. Development Guidelines
### Key Commands
*   **Setup**: `flutter pub get`
*   **Run**: `flutter run`
*   **Test**: `flutter test` (Standard unit/widget tests)
*   **Integration Test**: `flutter test integration_test/`
*   **Safe Test Run (Recommended)**: 
    ```bash
    set -o pipefail; flutter test --coverage | tee flutter_test_latest.log
    ```
    *Always use this command to capture logs and ensure comprehensive coverage checks.*

### Code Standards
*   **Style**: Strict adherence to `analysis_options.yaml`.
*   **Logging**: Use the `logging` package. **NEVER** use `print()`.
*   **Testing**:
    *   All BLE interactions must use `IBLEPlatformHost` to allow mocking.
    *   DB tests must use `TestSetup.initializeTestEnvironment()` to ensure isolated SQLCipher instances.

## 6. Current Implementation Status (Nov 2025)
Based on `PAKCONNECT_TECHNICAL_SPECIFICATIONS.md`:
*   **Phase 3 (Advanced UI)**: 
    *   ✅ UI components for Archive, Search, and Swipe actions are **Complete**.
    *   ✅ Swipe-to-archive and Context Menus are functional.
    *   ⚠️ **Pending**: Backend migration for the Archive system (moving from SharedPreferences to SQLite) and Advanced Search logic (Fuzzy search implementation).
*   **Phase 4 (Polish)**: Upcoming phase for comprehensive testing and optimization.

## 7. Documentation Map
*   **`AGENTS.md`**: **READ THIS FIRST.** The definitive guide for AI agents working on this repo. Contains strict protocol rules and "Confidence Protocol".
*   **`CLAUDE.md`**: Companion guide with deep implementation details for Claude (useful for context).
*   **`docs/claude/`**: Detailed architectural deep dives (BLE, Noise, Mesh, Database).
*   **`PAKCONNECT_TECHNICAL_SPECIFICATIONS.md`**: Current roadmap and feature specifications.
