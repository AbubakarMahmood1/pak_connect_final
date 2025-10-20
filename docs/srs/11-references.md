# References

## Overview

This section lists all standards, specifications, documentation, and third-party resources referenced in the PakConnect System Requirements Specification (SRS).

---

## Standards and Specifications

### [1] ISO/IEC/IEEE 29148:2018
**Title**: Systems and software engineering — Life cycle processes — Requirements engineering

**Publisher**: International Organization for Standardization (ISO), International Electrotechnical Commission (IEC), Institute of Electrical and Electronics Engineers (IEEE)

**Year**: 2018

**Description**: Current international standard for software requirements specifications, supersedes IEEE 830-1998.

**Relevance**: Document structure and requirements format follow this standard.

**URL**: https://www.iso.org/standard/72089.html

---

### [2] IEEE 830-1998
**Title**: IEEE Recommended Practice for Software Requirements Specifications

**Publisher**: Institute of Electrical and Electronics Engineers (IEEE)

**Year**: 1998

**Status**: Superseded by ISO/IEC/IEEE 29148:2018, but widely referenced

**Description**: Defines recommended approach for specification of software requirements.

**Relevance**: Legacy standard referenced in academic contexts.

**URL**: https://ieeexplore.ieee.org/document/720574

---

### [3] IEEE 829-2008
**Title**: IEEE Standard for Software and System Test Documentation

**Publisher**: Institute of Electrical and Electronics Engineers (IEEE)

**Year**: 2008

**Description**: Standard for test documentation, separate from SRS.

**Relevance**: Referenced in Section 3.4 (Other Requirements) for testing practices.

**URL**: https://ieeexplore.ieee.org/document/4578383

---

## Cryptographic Standards and Specifications

### [4] Noise Protocol Framework (Revision 34)
**Title**: The Noise Protocol Framework

**Author**: Trevor Perrin (noise@trevp.net)

**Revision**: 34 (2018-07-11)

**Status**: Official/Unstable

**Description**: Framework for building crypto protocols based on Diffie-Hellman key agreement. Defines XX, KK, and other handshake patterns.

**Relevance**: Core cryptographic protocol used in PakConnect for end-to-end encryption.

**Implementation**: Sections 3.2 (Functional Requirements - Security), 4.5 (Sequence Diagrams), 7 (Class Diagrams - NoiseSession)

**URL**: https://noiseprotocol.org/noise.html

**PDF**: https://noiseprotocol.org/noise.pdf

**Citation**:
> Perrin, T. (2018). *The Noise Protocol Framework (Revision 34)*. Retrieved from https://noiseprotocol.org/noise.html

---

### [5] RFC 7539
**Title**: ChaCha20 and Poly1305 for IETF Protocols

**Authors**: Y. Nir, A. Langley

**Publisher**: Internet Engineering Task Force (IETF)

**Year**: 2015

**Category**: Standards Track

**Description**: Specifies ChaCha20-Poly1305 Authenticated Encryption with Associated Data (AEAD) cipher suite.

**Relevance**: AEAD cipher used within Noise Protocol sessions for message encryption.

**Implementation**: Used by `cryptography` package (Dart dependency)

**URL**: https://www.rfc-editor.org/rfc/rfc7539

**Citation**:
> Nir, Y., & Langley, A. (2015). *ChaCha20 and Poly1305 for IETF Protocols* (RFC 7539). IETF. https://doi.org/10.17487/RFC7539

---

### [6] RFC 7748
**Title**: Elliptic Curves for Security

**Authors**: A. Langley, M. Hamburg, S. Turner

**Publisher**: Internet Engineering Task Force (IETF)

**Year**: 2016

**Category**: Informational

**Description**: Specifies X25519 (Curve25519) Diffie-Hellman key exchange.

**Relevance**: Key exchange algorithm used in Noise Protocol handshakes.

**Implementation**: Used by `pinenacl` package (Dart dependency)

**URL**: https://www.rfc-editor.org/rfc/rfc7748

**Citation**:
> Langley, A., Hamburg, M., & Turner, S. (2016). *Elliptic Curves for Security* (RFC 7748). IETF. https://doi.org/10.17487/RFC7748

---

### [7] NIST FIPS 180-4
**Title**: Secure Hash Standard (SHS)

**Publisher**: National Institute of Standards and Technology (NIST)

**Year**: 2015

**Description**: Defines SHA-256, SHA-384, SHA-512 hash functions.

**Relevance**: SHA-256 used for message ID generation, key derivation (HKDF), and integrity verification.

**Implementation**: Used by `crypto` package (Dart dependency)

**URL**: https://csrc.nist.gov/publications/detail/fips/180/4/final

**Citation**:
> National Institute of Standards and Technology. (2015). *FIPS PUB 180-4: Secure Hash Standard (SHS)*. U.S. Department of Commerce. https://doi.org/10.6028/NIST.FIPS.180-4

---

### [8] NIST SP 800-108
**Title**: Recommendation for Key Derivation Using Pseudorandom Functions

**Publisher**: National Institute of Standards and Technology (NIST)

**Year**: 2009

**Description**: Defines HKDF (HMAC-based Key Derivation Function) used in Noise Protocol.

**Relevance**: Key derivation for Noise sessions and database encryption.

**URL**: https://csrc.nist.gov/publications/detail/sp/800-108/final

**Citation**:
> Chen, L. (2009). *NIST Special Publication 800-108: Recommendation for Key Derivation Using Pseudorandom Functions*. NIST. https://doi.org/10.6028/NIST.SP.800-108

---

### [9] NIST SP 800-132
**Title**: Recommendation for Password-Based Key Derivation

**Publisher**: National Institute of Standards and Technology (NIST)

**Year**: 2010

**Description**: Defines PBKDF2 (Password-Based Key Derivation Function 2).

**Relevance**: Used for database encryption key derivation from device-specific entropy.

**Implementation**: `lib/data/database/database_encryption.dart` (PBKDF2-SHA512, 100,000 iterations)

**URL**: https://csrc.nist.gov/publications/detail/sp/800-132/final

**Citation**:
> Turan, M. S., Barker, E., Burr, W., & Chen, L. (2010). *NIST Special Publication 800-132: Recommendation for Password-Based Key Derivation*. NIST. https://doi.org/10.6028/NIST.SP.800-132

---

## Bluetooth Standards

### [10] Bluetooth Core Specification v5.0
**Title**: Bluetooth Core Specification Version 5.0

**Publisher**: Bluetooth Special Interest Group (SIG)

**Year**: 2016

**Description**: Defines Bluetooth Low Energy (BLE) protocol, GATT (Generic Attribute Profile), and dual-role architecture.

**Relevance**: BLE communication stack used for peer-to-peer messaging and mesh networking.

**Implementation**: Sections 3.2 (Functional Requirements - BLE), 4.7 (Class Diagrams - BLE Layer)

**URL**: https://www.bluetooth.com/specifications/specs/core-specification-5-0/

**Citation**:
> Bluetooth Special Interest Group. (2016). *Bluetooth Core Specification Version 5.0*. Bluetooth SIG.

---

### [11] GATT Specification Supplement v8
**Title**: GATT Specification Supplement

**Publisher**: Bluetooth Special Interest Group (SIG)

**Year**: 2021

**Description**: Defines standard GATT services and characteristics.

**Relevance**: Custom GATT services for PakConnect messaging protocol.

**URL**: https://www.bluetooth.com/specifications/specs/gatt-specification-supplement-8/

---

## Software and Framework Documentation

### [12] Flutter Documentation
**Title**: Flutter Documentation

**Publisher**: Google LLC

**Version**: 3.9+

**Year**: 2024

**Description**: Official documentation for Flutter framework.

**Relevance**: Application built using Flutter SDK 3.9.0+.

**URL**: https://docs.flutter.dev/

**Specific References**:
- Platform Channels: https://docs.flutter.dev/platform-integration/platform-channels
- State Management: https://docs.flutter.dev/data-and-backend/state-mgmt

---

### [13] Dart Language Specification
**Title**: Dart Programming Language Specification

**Publisher**: Google LLC

**Version**: 3.9+

**Year**: 2024

**Description**: Official specification for Dart programming language.

**Relevance**: Application implemented in Dart 3.9.0+.

**URL**: https://dart.dev/guides/language/spec

---

### [14] Riverpod Documentation
**Title**: Riverpod - A Reactive Caching and Data-binding Framework

**Author**: Remi Rousselet

**Version**: 3.0+

**Year**: 2024

**Description**: State management library for Flutter.

**Relevance**: Used for application state management (providers pattern).

**Implementation**: All providers in `lib/presentation/providers/`

**URL**: https://riverpod.dev/

**GitHub**: https://github.com/rrousselGit/riverpod

---

## Database and Encryption

### [15] SQLite Documentation
**Title**: SQLite Database Engine

**Version**: 3.x

**Publisher**: SQLite Consortium

**Year**: 2024

**Description**: Embedded relational database engine.

**Relevance**: Local data persistence, schema version 9.

**Implementation**: Section 4.14 (Database Schema), `lib/data/database/database_helper.dart`

**URL**: https://www.sqlite.org/docs.html

---

### [16] SQLCipher Documentation
**Title**: SQLCipher - SQLite Extension for Database Encryption

**Version**: 4.x

**Publisher**: Zetetic LLC

**Year**: 2024

**Description**: Transparent 256-bit AES encryption for SQLite databases.

**Relevance**: Database encryption (AES-256-CBC, PBKDF2 key derivation).

**Implementation**: `sqflite_sqlcipher` Dart package

**URL**: https://www.zetetic.net/sqlcipher/

**GitHub**: https://github.com/sqlcipher/sqlcipher

**Citation**:
> Zetetic LLC. (2024). *SQLCipher: SQLite Extension Providing Transparent 256-bit AES Encryption*. Retrieved from https://www.zetetic.net/sqlcipher/

---

## Third-Party Libraries and Packages

### [17] pinenacl (Dart Package)
**Package**: pinenacl

**Version**: 0.6.0

**Author**: Teja Aluru

**Description**: Dart implementation of libsodium/NaCl cryptographic library. Provides X25519 key exchange.

**Relevance**: X25519 Diffie-Hellman operations in Noise Protocol.

**License**: Apache 2.0

**URL**: https://pub.dev/packages/pinenacl

**Repository**: https://github.com/ilap/pinenacl-dart

---

### [18] cryptography (Dart Package)
**Package**: cryptography

**Version**: 2.7.0

**Author**: Dart team / gohilla

**Description**: Pure Dart cryptographic algorithms including ChaCha20-Poly1305.

**Relevance**: AEAD cipher for Noise Protocol message encryption.

**License**: Apache 2.0

**URL**: https://pub.dev/packages/cryptography

**Repository**: https://github.com/dint-dev/cryptography

---

### [19] bluetooth_low_energy (Flutter Plugin)
**Package**: bluetooth_low_energy

**Version**: 6.1.0

**Author**: yangbo on pub.dev

**Description**: Cross-platform BLE plugin supporting central and peripheral modes simultaneously.

**Relevance**: BLE communication stack, dual-role support.

**License**: MIT

**URL**: https://pub.dev/packages/bluetooth_low_energy

**Repository**: https://github.com/yanshouwang/bluetooth_low_energy

---

### [20] sqflite_sqlcipher (Flutter Plugin)
**Package**: sqflite_sqlcipher

**Version**: 3.2.1

**Author**: Tekartik

**Description**: SQLite plugin with SQLCipher encryption support.

**Relevance**: Encrypted local database storage.

**License**: MIT

**URL**: https://pub.dev/packages/sqflite_sqlcipher

**Repository**: https://github.com/tekartik/sqflite_sqlcipher

---

## Academic and Research Papers

### [21] Kobeissi, N., Nicolas, G., & Bhargavan, K. (2019)
**Title**: Noise Explorer: Fully Automated Modeling and Verification for Arbitrary Noise Protocols

**Conference**: IEEE European Symposium on Security and Privacy (EuroS&P)

**Year**: 2019

**Description**: Formal verification of Noise Protocol patterns using automated tools.

**Relevance**: Security analysis of XX and KK patterns used in PakConnect.

**DOI**: 10.1109/EuroSP.2019.00036

**URL**: https://www.wireguard.com/papers/kobeissi-bhargavan-noise-explorer-2018.pdf

**Citation**:
> Kobeissi, N., Nicolas, G., & Bhargavan, K. (2019). Noise Explorer: Fully Automated Modeling and Verification for Arbitrary Noise Protocols. *2019 IEEE European Symposium on Security and Privacy (EuroS&P)*, 356–370. https://doi.org/10.1109/EuroSP.2019.00036

---

### [22] Girol, G., Feitosa, E., & Tucci-Piergiovanni, S. (2020)
**Title**: Analyzing the Noise Protocol Framework

**Conference**: IACR Public-Key Cryptography (PKC) 2020

**Year**: 2020

**Description**: Cryptographic analysis of Noise Protocol security properties.

**Relevance**: Theoretical foundation for security guarantees.

**URL**: https://www.iacr.org/archive/pkc2020/12110122/12110122.pdf

---

### [23] Bernstein, D. J. (2006)
**Title**: Curve25519: New Diffie-Hellman Speed Records

**Conference**: Public Key Cryptography (PKC) 2006

**Year**: 2006

**Description**: Original paper on Curve25519 (X25519) key exchange algorithm.

**Relevance**: Foundational algorithm for Noise Protocol DH operations.

**DOI**: 10.1007/11745853_14

**Citation**:
> Bernstein, D. J. (2006). Curve25519: New Diffie-Hellman Speed Records. *Public Key Cryptography - PKC 2006*, 207–228. https://doi.org/10.1007/11745853_14

---

### [24] Nir, Y., & Josefsson, S. (2017)
**Title**: ChaCha20-Poly1305 Cipher Suites for Transport Layer Security (TLS)

**Publisher**: IETF

**RFC**: 7905

**Year**: 2016

**Description**: Integration of ChaCha20-Poly1305 in TLS protocol.

**Relevance**: Real-world deployment of cipher used in PakConnect.

**URL**: https://www.rfc-editor.org/rfc/rfc7905

**Citation**:
> Nir, Y., & Josefsson, S. (2016). *ChaCha20-Poly1305 Cipher Suites for Transport Layer Security (TLS)* (RFC 7905). IETF. https://doi.org/10.17487/RFC7905

---

## Platform-Specific Documentation

### [25] Android Developers - Bluetooth Low Energy
**Title**: Bluetooth Low Energy Overview

**Publisher**: Google LLC (Android Open Source Project)

**Year**: 2024

**Description**: Official Android BLE API documentation.

**Relevance**: Platform-specific BLE implementation for Android.

**URL**: https://developer.android.com/guide/topics/connectivity/bluetooth/ble-overview

---

### [26] Apple Developer - Core Bluetooth
**Title**: Core Bluetooth Programming Guide

**Publisher**: Apple Inc.

**Year**: 2024

**Description**: Official iOS/macOS BLE framework documentation.

**Relevance**: Platform-specific BLE implementation for iOS.

**URL**: https://developer.apple.com/documentation/corebluetooth

---

### [27] Android Developers - Security Best Practices
**Title**: Security and Privacy on Android

**Publisher**: Google LLC

**Year**: 2024

**Description**: Android platform security guidelines.

**Relevance**: Secure storage (FlutterSecureStorage), runtime permissions.

**URL**: https://developer.android.com/topic/security/best-practices

---

## Open Source Project References

### [28] Signal Protocol
**Title**: Signal Protocol (formerly TextSecure)

**Organization**: Signal Foundation

**Year**: 2024

**Description**: End-to-end encryption protocol used by Signal Messenger. Shares design principles with Noise Protocol.

**Relevance**: Inspiration for security architecture and ratcheting.

**URL**: https://signal.org/docs/

**GitHub**: https://github.com/signalapp/libsignal

---

### [29] WireGuard VPN
**Title**: WireGuard: Fast, Modern, Secure VPN Tunnel

**Author**: Jason A. Donenfeld

**Year**: 2024

**Description**: VPN protocol using Noise Protocol Framework for handshakes.

**Relevance**: Real-world production deployment of Noise Protocol.

**URL**: https://www.wireguard.com/

**Paper**: https://www.wireguard.com/papers/wireguard.pdf

---

## Regulatory and Privacy References

### [30] GDPR - General Data Protection Regulation
**Title**: Regulation (EU) 2016/679

**Publisher**: European Parliament and Council of the European Union

**Year**: 2016

**Description**: EU data protection and privacy regulation.

**Relevance**: Privacy policy compliance, data minimization principles.

**URL**: https://gdpr-info.eu/

---

### [31] Wassenaar Arrangement
**Title**: The Wassenaar Arrangement on Export Controls for Conventional Arms and Dual-Use Goods and Technologies

**Organization**: Wassenaar Arrangement Secretariat

**Year**: 2024

**Description**: Multilateral export control regime for cryptography.

**Relevance**: Cryptographic export compliance (Section 3.4.1, OR-3).

**URL**: https://www.wassenaar.org/

---

## Tools and Testing

### [32] sqflite_common_ffi (Dart Package)
**Package**: sqflite_common_ffi

**Version**: 2.3.4

**Author**: Tekartik

**Description**: SQLite FFI implementation for desktop testing.

**Relevance**: Database testing on desktop platforms (Windows, macOS, Linux).

**License**: MIT

**URL**: https://pub.dev/packages/sqflite_common_ffi

---

### [33] Flutter Test Documentation
**Title**: Testing Flutter Apps

**Publisher**: Google LLC

**Year**: 2024

**Description**: Official guide for unit, widget, and integration testing in Flutter.

**Relevance**: Test methodology (Section 3.4.8, OR-24).

**URL**: https://docs.flutter.dev/testing

---

## Project-Specific Documentation

### [34] PakConnect Privacy Policy
**Location**: `assets/privacy_policy.md` (internal)

**Description**: Application privacy policy, accessible to users within app.

**Relevance**: Legal compliance (Section 3.4.1, OR-2).

---

### [35] PakConnect CLAUDE.md
**Location**: `CLAUDE.md` (project root, internal)

**Description**: Developer guidance document for Claude Code AI assistant.

**Relevance**: Architecture overview, development patterns, and coding standards.

---

## Additional Resources

### [36] pub.dev - Dart Package Repository
**Title**: pub.dev

**Publisher**: Dart team (Google LLC)

**Year**: 2024

**Description**: Official package repository for Dart and Flutter.

**Relevance**: Source for all third-party dependencies.

**URL**: https://pub.dev/

---

## Citation Format Note

This document uses a hybrid citation format combining IEEE and APA styles:
- **Standards and RFCs**: IEEE format with DOI links
- **Academic Papers**: APA format with DOI
- **Software Documentation**: Informal format with version numbers and URLs
- **All references**: Numbered sequentially for easy cross-referencing within SRS

---

## Last Updated
**Date**: 2025-01-19

**Total References**: 36

**Categories**:
- Standards (3)
- Cryptographic Specifications (9)
- Bluetooth Standards (2)
- Software Documentation (3)
- Third-Party Packages (7)
- Academic Papers (4)
- Platform Documentation (3)
- Open Source Projects (2)
- Regulatory (2)
- Tools (1)

**Cross-Reference Usage**: References are cited throughout the SRS using `[Reference Number]` notation in relevant sections.
