# Other Requirements

## Overview

This document specifies additional requirements not covered under functional or non-functional categories, including legal, regulatory, hardware, installation, and operational constraints.

---

## 3.4.1 Legal and Regulatory Requirements

### OR-1: Open Source Licensing
**Requirement**: The application MUST be distributed under an open-source license compatible with all third-party dependencies.

**Details**:
- Primary license: MIT License (as indicated by `publish_to: 'none'` in pubspec.yaml)
- All dependencies use compatible licenses (BSD, MIT, Apache 2.0)
- No proprietary components

**Verification**: Review LICENSE file and third-party licenses

---

### OR-2: Privacy Policy Compliance
**Requirement**: The application MUST include a privacy policy accessible to users.

**Implementation**:
- Privacy policy stored in `assets/privacy_policy.md`
- Accessible via in-app settings
- Complies with GDPR principles (data minimization, user control)

**Reference**: `pubspec.yaml:95` (privacy_policy.md asset)

---

### OR-3: Export Control Compliance
**Requirement**: Cryptographic implementations MUST comply with export control regulations.

**Details**:
- Uses publicly available cryptographic libraries (pinenacl, cryptography)
- No custom/proprietary encryption algorithms
- X25519 (public domain), ChaCha20-Poly1305 (RFC 7539), SHA-256 (NIST FIPS 180-4)

**Jurisdictions**: Designed for international use with standard crypto

---

### OR-4: User Consent for Permissions
**Requirement**: The application MUST request explicit user consent before accessing device features.

**Affected Permissions**:
- Bluetooth (BLE scanning/advertising)
- Notifications
- Storage (for exports)
- Camera (for QR code scanning)

**Implementation**: `permission_handler` package (v12.0.1)

---

## 3.4.2 Hardware Requirements

### OR-5: Bluetooth Low Energy Support
**Requirement**: Device MUST support Bluetooth 4.2 or higher with GATT server and client roles.

**Specifications**:
- BLE 4.2+ (for simultaneous central/peripheral mode)
- Minimum MTU: 23 bytes (default GATT)
- Recommended MTU: 512 bytes (for performance)

**Platform Support**: Android, iOS, Windows (via `bluetooth_low_energy` plugin)

---

### OR-6: Minimum Android SDK
**Requirement**: Android devices MUST run API level 21 (Android 5.0 Lollipop) or higher.

**Rationale**:
- BLE GATT server support requires API 21+
- SQLCipher native libraries require API 21+
- Flutter framework compatibility

**Reference**: `android/app/build.gradle.kts:28` (`minSdk = flutter.minSdkVersion`)

---

### OR-7: iOS Version Requirement
**Requirement**: iOS devices MUST run iOS 12.0 or higher.

**Rationale**:
- Flutter 3.9+ requires iOS 12.0+
- Core Bluetooth framework stability
- Background BLE support

**Reference**: Flutter documentation, `ios/Podfile` (minimum deployment target)

---

### OR-8: Storage Capacity
**Requirement**: Device MUST have at least 100 MB of available storage.

**Breakdown**:
- App binary: ~20-30 MB
- Database: ~10-50 MB (depending on message history)
- Cached data: ~10 MB
- User exports: Variable

---

### OR-9: RAM Requirement
**Requirement**: Device SHOULD have at least 2 GB of RAM for optimal performance.

**Rationale**:
- Cryptographic operations (Noise sessions, key derivation)
- Simultaneous BLE connections (up to 7)
- UI rendering with Flutter

---

## 3.4.3 Installation Requirements

### OR-10: Flutter SDK Version
**Requirement**: Development requires Flutter SDK 3.9.0 or higher.

**Reference**: `pubspec.yaml:22` (`sdk: ">=3.9.0 <4.0.0"`)

---

### OR-11: Platform-Specific Build Tools
**Requirement**: Building the application requires platform-specific toolchains.

**Android**:
- Android SDK 33 (compileSdk)
- NDK r27 (27.0.12077973) for native crypto libraries
- Java 11 (JDK)
- Kotlin plugin
- Gradle 8.0+

**iOS**:
- Xcode 14.0+
- CocoaPods 1.11+
- Swift 5.5+

**Windows**:
- Visual Studio 2022 (Desktop development with C++)
- Windows 10 SDK

**Reference**: `android/app/build.gradle.kts:11` (NDK version), Flutter documentation

---

### OR-12: Dependency Installation
**Requirement**: All dependencies MUST be fetched via `flutter pub get` before building.

**Critical Dependencies**:
- `riverpod: ^3.0.0` (state management)
- `bluetooth_low_energy: ^6.1.0` (BLE stack)
- `pinenacl: ^0.6.0` (X25519 DH)
- `cryptography: ^2.7.0` (ChaCha20-Poly1305)
- `sqflite_sqlcipher: ^3.2.1` (encrypted database)

**Reference**: `pubspec.yaml:37-66`

---

### OR-13: First Launch Initialization
**Requirement**: On first launch, the application MUST:
1. Generate static identity keypair (X25519)
2. Create encrypted database with random encryption key
3. Request necessary runtime permissions
4. Initialize BLE adapter

**Time**: Initialization completes within 5 seconds on average hardware

**Reference**: `lib/core/app_core.dart` (AppCore.initialize())

---

## 3.4.4 Runtime Permissions (Android)

### OR-14: Android Bluetooth Permissions
**Requirement**: The application MUST request the following permissions at runtime.

**Android 12+ (API 31+)**:
```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
```

**Android 11 and below (API 30-)**:
```xml
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
```

**Rationale**: BLE scanning requires location permission (privacy protection per Android policy)

---

### OR-15: Notification Permissions
**Requirement**: The application MUST request notification permission on Android 13+ (API 33+).

**Implementation**:
```xml
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
```

**Reference**: `android/app/src/main/AndroidManifest.xml:3`

---

### OR-16: Background Execution Permissions
**Requirement**: The application requests the following permissions for background operation.

**Permissions**:
```xml
<uses-permission android:name="android.permission.WAKE_LOCK"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
```

**Purpose**:
- WAKE_LOCK: Process offline message queue retries
- RECEIVE_BOOT_COMPLETED: Restart background workers after device reboot

**Reference**: `android/app/src/main/AndroidManifest.xml:5-6`

---

## 3.4.5 Network and Connectivity Requirements

### OR-17: No Internet Requirement
**Requirement**: The application MUST function fully without internet connectivity.

**Rationale**: Designed as a peer-to-peer mesh network using only BLE (no cloud services)

**Exception**: None (truly offline-first architecture)

---

### OR-18: BLE Range Limitations
**Requirement**: Users MUST be aware that BLE communication range is limited to approximately 10-30 meters line-of-sight.

**Factors Affecting Range**:
- Physical obstructions (walls, furniture)
- Radio interference (Wi-Fi, other BLE devices)
- Device antenna quality
- Transmission power settings

**Mesh Extension**: Multi-hop relay can extend effective range beyond direct BLE limits

---

## 3.4.6 Data Retention and Archival

### OR-19: Archive Storage Limits
**Requirement**: Archived messages MUST be managed to prevent unlimited storage growth.

**Policy**:
- Maximum 10,000 archived messages (configurable)
- Oldest archives auto-deleted when limit reached
- User notified before auto-deletion
- Manual export recommended for long-term storage

**Reference**: Archive system implementation in `lib/data/repositories/archive_repository.dart`

---

### OR-20: Database Maintenance
**Requirement**: The application SHOULD perform periodic database maintenance.

**Operations**:
- VACUUM command (reclaim space) - monthly or when DB size > 100 MB
- Delete messages older than 1 year (optional, user-configurable)
- Clean up orphaned Noise sessions (no contact, >7 days old)

**Implementation**: Background job via `workmanager` package

---

## 3.4.7 Cryptographic Requirements

### OR-21: Secure Random Number Generation
**Requirement**: All cryptographic operations MUST use cryptographically secure random number generators.

**Sources**:
- Dart: `dart:math` Random.secure()
- Native: Android SecureRandom, iOS SecRandomCopyBytes

**Usage**: Key generation, nonce generation, session IDs

---

### OR-22: Key Derivation Standards
**Requirement**: Encryption keys MUST be derived using industry-standard KDFs.

**Implementations**:
- Database encryption: PBKDF2-SHA512 (100,000 iterations)
- Noise protocol: HKDF-SHA256 (per Noise spec)

**Reference**: `lib/data/database/database_encryption.dart`

---

### OR-23: Cryptographic Library Verification
**Requirement**: All cryptographic libraries MUST be well-audited and actively maintained.

**Libraries Used**:
- **pinenacl** (v0.6.0): Dart port of libsodium (NaCl), X25519 implementation
- **cryptography** (v2.7.0): Pure Dart crypto library, ChaCha20-Poly1305
- **crypto** (v3.0.6): Official Dart crypto package, SHA-256

**Audit Status**: All are widely used in production Flutter apps

---

## 3.4.8 Testing and Quality Assurance

### OR-24: Test Coverage Requirement
**Requirement**: Unit and integration tests SHOULD achieve >85% code coverage.

**Tested Components**:
- Core cryptographic operations (Noise protocol)
- Database migrations and CRUD operations
- BLE message fragmentation/reassembly
- Mesh relay logic and routing

**Test Framework**: `flutter_test`, `sqflite_common_ffi` (for desktop testing)

**Reference**: `test/` directory

---

### OR-25: Real Device Testing
**Requirement**: BLE functionality MUST be tested on real devices (emulators insufficient).

**Rationale**:
- Android emulators lack BLE hardware support
- iOS simulator does not support Core Bluetooth
- Connection stability, MTU negotiation, and dual-role operation require physical hardware

**Minimum Test Devices**: 2 physical devices (Android or iOS) for peer-to-peer testing

---

## 3.4.9 Deployment and Distribution

### OR-26: Build Variants
**Requirement**: The application SHOULD support debug and release build variants.

**Debug Build**:
- Verbose logging enabled (all log levels)
- Debug signing certificate
- Larger APK size (unoptimized)

**Release Build**:
- Minimal logging (warnings and errors only)
- ProGuard/R8 code obfuscation
- Optimized APK size

**Command**: `flutter build apk --release`

---

### OR-27: Code Signing
**Requirement**: Release builds MUST be signed with a valid certificate.

**Android**:
- App signing key (RSA 2048-bit minimum)
- Keystore stored securely (not in repository)

**iOS**:
- Apple Developer Certificate
- Provisioning profile

**Reference**: `android/app/build.gradle.kts:38` (debug signing for development)

---

### OR-28: No Telemetry or Analytics
**Requirement**: The application MUST NOT collect or transmit user data to third-party servers.

**Verification**:
- No analytics SDKs (Firebase, Crashlytics, etc.)
- No network requests to external servers
- All data stored locally (encrypted SQLite)

**Privacy Guarantee**: Zero data leaves the device except via explicit user action (exports, QR sharing)

---

## 3.4.10 Accessibility Requirements

### OR-29: Screen Reader Compatibility
**Requirement**: The application SHOULD be compatible with platform screen readers.

**Implementation**:
- Semantic labels on interactive widgets
- TalkBack support (Android)
- VoiceOver support (iOS)

**Coverage**: Core messaging flows, contact management, settings

---

### OR-30: Minimum Font Size
**Requirement**: Text SHOULD be readable at system font size settings.

**Implementation**:
- Respect system font scale factor
- Minimum font size: 14sp (body text)
- Support font scaling up to 200%

---

## 3.4.11 Backup and Recovery

### OR-31: Database Backup
**Requirement**: Users SHOULD be able to export encrypted database backups.

**Format**: Encrypted SQLite database file (.db) with separate encryption key
**Trigger**: Manual export via settings
**Restoration**: Manual import with encryption key

**Limitation**: Noise session states are ephemeral and NOT included in backups (sessions re-established on next connection)

---

### OR-32: Chat Export
**Requirement**: Users MUST be able to export individual chat histories.

**Formats**:
- JSON (machine-readable, structured)
- Plain text (human-readable, decrypted content)

**Implementation**: `share_plus` package for system share dialog

**Reference**: Chat export feature in `lib/presentation/screens/chat_screen.dart`

---

## Summary

**Total Other Requirements**: 32

**Categories**:
- Legal & Regulatory: 4 requirements
- Hardware: 5 requirements
- Installation: 4 requirements
- Runtime Permissions: 3 requirements
- Network & Connectivity: 2 requirements
- Data Retention: 2 requirements
- Cryptographic: 3 requirements
- Testing & QA: 2 requirements
- Deployment: 3 requirements
- Accessibility: 2 requirements
- Backup & Recovery: 2 requirements

**Last Updated**: 2025-01-19
