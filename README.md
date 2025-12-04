# PakConnect 🛡️📡

[![Flutter](https://img.shields.io/badge/Flutter-3.9%2B-02569B?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.9%2B-0175C2?logo=dart)](https://dart.dev)
[![State Management](https://img.shields.io/badge/State-Riverpod_3.0-purple)](https://riverpod.dev)
[![Security](https://img.shields.io/badge/Encryption-Noise_XX%2FKK-green)](https://noiseprotocol.org)
[![Database](https://img.shields.io/badge/Storage-SQLCipher-blue)](https://www.zetetic.net/sqlcipher/)
[![License](https://img.shields.io/badge/License-Proprietary-red)]()

> **Secure, decentralized, peer-to-peer messaging for off-grid communication.**

PakConnect is a cutting-edge Flutter application designed for environments where internet connectivity is unreliable or unavailable. It leverages **BLE (Bluetooth Low Energy) Mesh Networking** and the **Noise Protocol Framework** to deliver military-grade, end-to-end encrypted messaging without central servers.

---

## 🚀 Key Features

### 🔐 **Zero-Trust Security**
*   **End-to-End Encryption**: Implements **Noise Protocol (XX/KK patterns)** using X25519 and ChaCha20-Poly1305.
*   **Perfect Forward Secrecy**: Ephemeral keys rotate per session; old messages remain secure even if long-term keys are compromised.
*   **Secure Storage**: All local data is encrypted at rest using **SQLCipher**.
*   **Identity Protection**: Dual-layer identity system (Immutable Public Key + Rotatable Ephemeral IDs) to prevent tracking.

### 🕸️ **Smart Mesh Networking**
*   **Off-Grid Communication**: Messages hop across devices (up to 5 hops) to reach their destination without internet.
*   **Intelligent Routing**: Custom `MeshRelayEngine` with topology awareness, duplicate detection, and TTL management.
*   **Dual-Role BLE**: Powered by `BLEServiceFacade` (`lib/data/services/ble_service_facade.dart`), acting as both Central and Peripheral.
*   **Offline-First**: Robust store-and-forward queues ensure messages are delivered when paths become available.

### 📱 **Modern User Experience**
*   **Rich Messaging**: Text, emojis, and binary payloads.
*   **Archive System**: Organize chats with swipe actions, search, and secure storage.
*   **Network Visualization**: Real-time view of the mesh topology and connected peers.
*   **Privacy Controls**: Toggle "Spy Mode," read receipts, and online status broadcasting.

---

## 🏗️ Architecture

PakConnect follows a strict **Clean Layered Architecture** to ensure scalability, testability, and maintainability.

```mermaid
graph TD
    subgraph Presentation ["🎨 Presentation Layer"]
        UI[Screens & Widgets]
        State[Riverpod Providers]
    end

    subgraph Domain ["🧠 Domain Layer"]
        UseCase[Use Cases]
        Entities[Business Entities]
        Interfaces[Repository Interfaces]
    end

    subgraph Data ["💾 Data Layer"]
        RepoImpl[Repository Implementations]
        DataSource[Data Sources (SQLCipher, BLE)]
        DTOs[Data Transfer Objects]
    end

    subgraph Core ["⚙️ Core Layer"]
        Mesh[Mesh Relay Engine]
        Noise[Noise Protocol Security]
        Infra[Infrastructure & Utils]
    end

    UI --> State
    State --> UseCase
    UseCase --> Interfaces
    RepoImpl --> Interfaces
    RepoImpl --> DataSource
    DataSource --> Core
```

### Tech Stack
*   **Framework**: Flutter 3.9+ / Dart 3.9+
*   **State Management**: Riverpod 3.0 (Code Generation)
*   **Database**: `sqflite` + `SQLCipher` (Schema v9)
*   **Cryptography**: `pinenacl` (X25519), `cryptography` (ChaCha20), `pointycastle`
*   **Hardware**: `bluetooth_low_energy` (Dual-Role)

---

## 🛠️ Getting Started

### Prerequisites
*   **Flutter SDK**: 3.9 or higher.
*   **Android/iOS Device**: Required for BLE features (Simulators do not support BLE).
*   **Development Environment**: VS Code or Android Studio.

### Installation

1.  **Clone the repository**
    ```bash
    git clone https://github.com/yourusername/pak_connect.git
    cd pak_connect
    ```

2.  **Install Dependencies**
    ```bash
    flutter pub get
    ```

3.  **Run the App**
    *   **Physical Device (Recommended)**:
        ```bash
        flutter run
        ```
    *   **Testing (VM-Friendly)**:
        ```bash
        flutter test
        ```

---

## 🚦 Project Status

| Phase | Feature Set | Status |
| :--- | :--- | :--- |
| **Phase 1** | **Core Transport** (BLE, Noise, Basic Mesh) | ✅ Complete |
| **Phase 2** | **Data Persistence** (SQLCipher, Migrations) | ✅ Complete |
| **Phase 3** | **Advanced UI** (Archive, Search, Swipe Actions) | ⚠️ In Progress (Backend Migration) |
| **Phase 4** | **Polish & Optimization** (Testing, Performance) | 🔄 Ongoing |

> **Note**: The Archive system's backend migration (moving from SharedPreferences to SQLite) and Advanced Search logic (Fuzzy search) are currently in active development.

---

## 🧪 Testing Strategy

We maintain a rigorous testing standard to ensure security and reliability.

*   **Unit Tests**: Cover domain logic and core algorithms.
*   **Integration Tests**: Verify database migrations and Noise handshake flows (`test/noise_end_to_end_test.dart`).
*   **Soak Tests**: Long-running stability tests located in `integration_test/` (Requires Hardware).
*   **Safe Test Run**:
    ```bash
    set -o pipefail; flutter test --coverage | tee flutter_test_latest.log
    ```

See `TESTING_STRATEGY.md` for detailed coverage goals and harness details.

---

## 📄 Documentation

*   [**AGENTS.md**](AGENTS.md): Protocol for AI Agents.
*   [**Technical Specifications**](PAKCONNECT_TECHNICAL_SPECIFICATIONS.md): Detailed roadmap and specs.
*   [**Security Architecture**](docs/claude/NOISE_INTEGRATION_PLAN.md): Deep dive into the Noise Protocol integration.

---

## 🤝 Contribution

This is a proprietary internal project. Access is restricted to authorized developers.

1.  Follow the **Clean Architecture** principles.
2.  **Never** use `print()`; use the `logging` package.
3.  Ensure all new features are covered by tests.
4.  Review `AGENTS.md` before making changes.

---

&copy; 2025 PakConnect. All rights reserved.
