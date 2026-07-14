# Other Requirements

## Overview

This document specifies additional requirements not covered under functional or non-functional categories, including legal, regulatory, hardware, installation, and operational constraints.

---

## 3.4.1 Legal and Regulatory Requirements

### OR-1: License Compliance
**Requirement**: The application MUST be distributed according to the root
`LICENSE`, and every bundled third-party dependency MUST retain its applicable
license and notice obligations.

**Details**:
- PakConnect is currently proprietary and confidential under the root
  `LICENSE`; a publicly visible repository does not make it open source.
- `publish_to: 'none'` prevents accidental pub.dev publication and says
  nothing about copyright licensing.
- Third-party dependency licenses remain their authors' licenses. A complete
  release/distribution audit is required before shipping binaries.

**Verification**: Review LICENSE file and third-party licenses

---

### OR-2: Privacy Policy Compliance
**Requirement**: The application MUST include a privacy policy accessible to users.

**Implementation**:
- Privacy policy stored in `assets/privacy_policy.md`
- Accessible via in-app settings
- Documents data minimization and user controls; no independent GDPR compliance
  audit is claimed

**Reference**: `pubspec.yaml` (`assets/privacy_policy.md`)

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

**Platform scope**: Android, iOS, and Windows source/build targets exist through
the `bluetooth_low_energy` plugin. Only the Android debug APK is currently
build-verified in the readiness ledger; real BLE behavior remains unverified
on all three platforms, and iOS/Windows must not be advertised as validated.

---

### OR-6: Minimum Android SDK
**Requirement**: The current Android build supports API level 24 (Android 7.0)
or higher.

**Rationale**:
- `android/app/build.gradle.kts` inherits `flutter.minSdkVersion`.
- The canonical Flutter 3.44.4 SDK resolves that value to API 24. The resolved
  platform values must be rechecked when the Flutter pin changes.
- Device validation should still include the oldest Android version the project
  intends to advertise.

**Reference**: `android/app/build.gradle.kts` (`minSdk = flutter.minSdkVersion`)

---

### OR-7: iOS Version Requirement
**Requirement**: iOS devices MUST run iOS 12.0 or higher.

**Rationale**:
- The Xcode project and Flutter framework metadata set a 12.0 deployment
  target.
- Background BLE behavior still requires physical-device validation.

**Reference**: `ios/Runner.xcodeproj/project.pbxproj`,
`ios/Flutter/AppFrameworkInfo.plist`

---

### OR-8: Storage Capacity
**Requirement**: Installation/storage capacity must be derived from a verified
artifact for the intended build mode and a documented data-retention target.

**Current evidence**:
- The verified debug APK for baseline `d5f6d7e` is 205,109,632 bytes; installed
  size can be larger.
- A 20-30 MB release binary is only a future optimization target until a
  signed release artifact is measured.
- Database, cache, and user-export storage vary with usage and have no current
  device-derived upper bound.

---

### OR-9: RAM Requirement
**Requirement**: Device SHOULD have at least 2 GB of RAM for optimal performance.

**Rationale**:
- Cryptographic operations (Noise sessions, key derivation)
- BLE connection handling (current payload policy is single-link; multi-link
  capacity is not device-verified)
- UI rendering with Flutter

---

## 3.4.3 Installation Requirements

### OR-10: Flutter SDK Version
**Requirement**: Development and CI require Flutter SDK 3.44.4 or higher; CI
and the committed lockfile are verified against Flutter 3.44.4.

**Reference**: `pubspec.yaml` (`sdk: ">=3.10.3 <4.0.0"` language floor,
`flutter: ">=3.44.4"`; the canonical Flutter release bundles Dart 3.12.2)

---

### OR-11: Platform-Specific Build Tools
**Requirement**: Building the application requires platform-specific toolchains.

**Android**:
- Android SDK 36 (`flutter.compileSdkVersion` /
  `flutter.targetSdkVersion` in the canonical Flutter 3.44.4 toolchain)
- NDK 28.2.13676358
- Java 17 (JDK; pinned in CI)
- Kotlin plugin 2.1.0 / Android Gradle Plugin 8.9.1
- Gradle 8.11.1 wrapper

**iOS**:
- macOS/Xcode toolchain capable of building the checked-in iOS project
- Exact Xcode/CocoaPods/Swift compatibility is not pinned or verified in the
  current Windows environment

**Windows**:
- Visual Studio 2022 (Desktop development with C++)
- Windows 10 SDK

**Reference**: `android/app/build.gradle.kts`, `android/settings.gradle.kts`,
`android/gradle/wrapper/gradle-wrapper.properties`

---

### OR-12: Dependency Installation
**Requirement**: All dependencies MUST be fetched via `flutter pub get` before building.

**Critical Dependencies**:
- `riverpod: ^3.0.0` (state management)
- `bluetooth_low_energy: ^6.2.1` (BLE stack)
- `pinenacl: ^0.6.0` (X25519 DH)
- `cryptography: ^2.7.0` (ChaCha20-Poly1305)
- `sqflite_sqlcipher: ^3.2.1` (encrypted database)

**Reference**: `pubspec.yaml`

---

### OR-13: First Launch Initialization
**Requirement**: On first launch, the application MUST:
1. Generate static identity keypair (X25519)
2. On Android/iOS, initialize the SQLCipher database path with a random key from
   platform secure storage; desktop/test mode may use plaintext SQLite
3. Request necessary runtime permissions
4. Initialize BLE adapter

**Time target**: Initialization should complete within 5 seconds, but no
current physical-device benchmark establishes that result.

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
**Requirement**: The Android manifest currently requests the following
permissions reserved for background/lifecycle work.

**Permissions**:
```xml
<uses-permission android:name="android.permission.WAKE_LOCK"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
```

**Purpose**:
- `WAKE_LOCK`: available to Android/Flutter components that need to keep work
  active while the process is running
- `RECEIVE_BOOT_COMPLETED`: declared, but no PakConnect boot receiver or Dart
  worker registration currently restarts queue work after reboot

**Implementation status**: Permission and dependency declarations are not
background-delivery evidence. The current app has in-process lifecycle/retry
logic and a resume flush, but no wired native WorkManager/service execution for
killed or dozing delivery.

**Reference**: `android/app/src/main/AndroidManifest.xml:5-6`

---

## 3.4.5 Network and Connectivity Requirements

### OR-17: No Internet Requirement
**Requirement**: Core PakConnect discovery, handshake, and message transport
MUST not require a project-operated internet service while both app processes
and BLE are available.

**Rationale**: Designed as a peer-to-peer mesh network using only BLE (no cloud services)

**Boundary**: Operating-system permission, notification, file/share, install,
and background-execution behavior remains platform-controlled. No-internet
transport does not imply killed-process delivery.

---

### OR-18: BLE Range Limitations
**Requirement**: Users MUST be aware that BLE range is hardware/environment
dependent. A historical 10-30 meter line-of-sight figure is a test target, not
current measured evidence.

**Factors Affecting Range**:
- Physical obstructions (walls, furniture)
- Radio interference (Wi-Fi, other BLE devices)
- Device antenna quality
- Transmission power settings

**Mesh extension**: Multi-hop relay is intended to extend effective range, but
that outcome remains gated on controlled three-device evidence.

---

## 3.4.6 Data Retention and Archival

### OR-19: Archive Storage Limits
**Requirement**: Archived messages MUST be managed to prevent unlimited storage growth.

**Policy**:
- Configuration exposes a 100 MiB storage cap and a 12-month maximum age
- Repository statistics can be compared with the configured storage cap
- Automatic cleanup, expiry removal, compression, index rebuild, and
  pre-deletion notification are not currently implemented
- Manual export recommended for long-term storage

**Status**: Partial. In-process maintenance/policy timers and configuration
surfaces exist, but maintenance task bodies and policy application are
placeholders that currently report no work.

**Reference**: `lib/domain/services/archive_management_models.dart`,
`archive_management_service.dart`, `archive_maintenance.dart`, and
`archive_policy_engine.dart`

---

### OR-20: Database Maintenance
**Requirement**: The application SHOULD perform periodic database maintenance.

**Operations**:
- VACUUM command (reclaim space) - monthly or when DB size > 100 MB
- Delete messages older than 1 year (optional, user-configurable)
- Clean up orphaned Noise sessions (no contact, >7 days old)

**Implementation status**: Maintenance methods exist, but no native/Dart
background task dependency or registration currently schedules this policy.
Treat it as an in-process/manual maintenance capability and an unwired
background requirement, not implemented reboot/killed-process work.

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
- Noise protocol: HKDF-SHA256 (per Noise spec)
- Export/import passphrases: PBKDF2-HMAC-SHA256 (600,000 iterations)
- Mobile database credential: random 256-bit value stored in platform secure
  storage and supplied to SQLCipher; it is not derived from an application
  passphrase

**References**: `lib/domain/services/encryption_utils.dart`,
`lib/data/database/database_encryption.dart`

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

**Enforcement status**: This is a target, not a current CI gate. The workflow
generates and uploads `coverage/lcov.info` but does not fail on a percentage.

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
- Optimized Flutter release build
- Release signing is mandatory; the Gradle build fails if signing credentials
  are absent

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

**Reference**: `android/app/build.gradle.kts` (release signing preflight)

---

### OR-28: No Telemetry or Analytics
**Requirement**: The application MUST NOT include project-operated telemetry,
analytics, advertising, account, or message-server collection unless the data
flow and privacy policy are explicitly revised.

**Verification**:
- No analytics SDKs (Firebase, Crashlytics, etc.)
- No project-operated network endpoint in the default runtime
- Local application data uses the SQLCipher path on Android/iOS; physical-device
  at-rest proof remains gated, and desktop/test factories may use plaintext
  SQLite
- BLE message, identity, acknowledgement, control, and routing-metadata flows
  are documented separately from server-side collection

**Privacy Boundary**: Data necessarily leaves the device during BLE messaging,
relay forwarding, pairing/identity exchange, acknowledgements, QR/contact
exchange, exports, backups, sharing, and other user-invoked platform flows. The
claim is no project-operated collection, not zero transmission.

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

**Format**: Self-contained `.pakconnect` v2.1.0 bundle. The database bytes,
metadata, preferences, and key material are encrypted with a
passphrase-derived key and authenticated with HMAC-SHA256.
**Trigger**: Manual export via settings
**Restoration**: Manual import with the export passphrase

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

**Last Updated**: 2026-07-11
