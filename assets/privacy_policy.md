# PakConnect Privacy Policy

**Last updated:** July 13, 2026

PakConnect is an offline-first Bluetooth messaging application. This policy
describes the current default runtime and its known limits; it does not turn
untested security behavior into a guarantee.

## Data handling

PakConnect does not require an account or a project-operated messaging server.
The current default runtime does not intentionally upload app analytics,
advertising identifiers, contacts, or message content to a PakConnect service.

The following data is stored locally:

- messages and delivery state;
- contacts, trust state, and public identity information;
- app settings;
- private key material and the mobile database credential through platform
  secure storage;
- user-created exports and locally cached media.

Data can leave a device when you explicitly use the product:

- messages, public/ephemeral identity data, acknowledgements, and routing
  metadata are exchanged with nearby peers over BLE;
- encrypted payloads can be forwarded through relay peers;
- QR/contact exchange shares the information shown by that flow;
- export, backup, share, file-picker, and notification actions invoke the
  selected operating-system facilities.

Android, iOS, device vendors, and installed system components may process
permission, notification, file, or Bluetooth metadata under their own
policies. “No PakConnect server” does not mean the operating system collects
nothing.

## Message encryption

User-message payloads use the Noise Protocol Framework:

- first-contact sessions use Noise XX;
- paired reconnects can use Noise KK;
- key agreement uses X25519;
- payload encryption uses ChaCha20-Poly1305;
- sessions rekey after the configured time/message limits.

Outbound user payloads are fail-closed when an established encryption session
is unavailable. Public keys and rotating ephemeral identifiers are protocol
identifiers and are necessarily exchanged; private keys are intended to remain
on the originating device.

This payload-confidentiality statement does not cover every byte sent over
BLE. Discovery advertisements, handshake/control frames, acknowledgements,
and routing metadata have separate exposure. The current relay path does not
enable sealed sender or stealth routing by default, so intermediate devices
may observe routing aliases even though they cannot read an encrypted inner
payload.

## Local database and exports

On Android and iOS, the production database path is designed to use SQLCipher
with a random 256-bit credential stored in platform secure storage. The app
fails closed if that mobile credential cannot be obtained. Physical-device
proof that the database file is unreadable without the credential remains a
release-validation gate.

Desktop and test environments may deliberately use plaintext SQLite when a
native SQLCipher library is unavailable. A desktop test pass is therefore not
mobile encryption-at-rest evidence.

Supported export v2.1 bundles derive a key from the user passphrase with PBKDF2,
AES-256-GCM encrypt metadata, keys, preferences, and database bytes, and apply
HMAC-SHA256 to the encrypted fields and restore metadata. Export/import
passphrases are separate from the random mobile database key. The embedded
database bytes have independent SQLCipher protection only when exported from
the Android/iOS SQLCipher path. Anyone who obtains an export file and its
passphrase may be able to read the exported data.

## Relay and metadata limits

Relay peers are untrusted. PakConnect applies duplicate, hop, size, rate, loop,
and queue controls and forwards encrypted inner payloads. It does not
currently guarantee sender/recipient metadata anonymity, trusted relay paths,
or per-hop re-encryption. Hashcash, sealed-sender, and stealth-addressing
primitives exist in the codebase but are not enabled as default production
guarantees.

## Your controls

The current app provides controls to:

- inspect and delete local chats/contacts;
- clear local app data;
- create and restore supported exports;
- deny or revoke Bluetooth and notification permissions through the operating
  system.

Deleting the app or its secure-storage credential may make an existing
encrypted database unrecoverable. Keep any export needed for recovery and
protect its passphrase.

## Known validation boundaries

Automated desktop tests cover protocol and state-machine behavior. They do not
prove real-radio interoperability, mobile database bytes at rest, delivery
while the OS has suspended/killed the process, signed-release behavior, or
three-device relay operation. Those claims remain gated on physical-device
evidence.

## Licensing and questions

PakConnect's source repository is publicly viewable, but the software is
currently distributed under the proprietary `LICENSE` in the repository root;
public visibility does not grant open-source reuse rights.

For questions, use the issue/contact channel published with the repository.

This policy should be updated whenever data flow, dependencies, transport,
storage, telemetry, or licensing changes.
