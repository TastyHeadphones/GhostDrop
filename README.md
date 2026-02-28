# GhostDrop

GhostDrop is an open-source, AirDrop-like nearby transfer system built on public Apple APIs only. It targets **iOS 26.0+** and **macOS 26.0+**, and focuses on realistic offline file exchange over BLE with transport negotiation:

- Prefer **L2CAP Credit-Based Channels** when available.
- Fallback to **GATT** with framing, sliding window, and retransmission.
- Use a unified frame transport API through `GhostTransport`.

`GhostDropKit` is the reusable Swift package. `Apps/GhostDropiOS` and `Apps/GhostDropmacOS` contain SwiftUI demo app sources.

## Why This Exists
BLE transfers between Apple devices are practical but nuanced:
- L2CAP availability is device/state dependent.
- GATT MTU and write flow control impose tight constraints.
- Real-world transfer UX needs state machines, verification, and resume support.

GhostDrop demonstrates a production-oriented architecture that works within public CoreBluetooth limitations.

## Quick Start
1. Open the repo in Xcode 26+.
2. Add `GhostDropKit` as a local package dependency.
3. Create two app targets from `Apps/GhostDropiOS` and `Apps/GhostDropmacOS` source files.
4. Add required Bluetooth/Local Network privacy keys (see **Info.plist & Entitlements Notes**).
5. Run one device in **Receive** mode and the other in **Send** mode.
6. Connect, compare SAS code, confirm, then transfer a file.

## Architecture

```text
+-----------------------------+            +-----------------------------+
|          SwiftUI App        |            |          SwiftUI App        |
|   (iOS/macOS MainActor UI)  |            |   (iOS/macOS MainActor UI)  |
+--------------+--------------+            +--------------+--------------+
               | AsyncStream<GhostEvent>                  |
               v                                           v
+--------------------------------------------------------------------------+
|                              SessionActor                                |
| handshake, SAS verification, transfer state machine, resume integration   |
+------------------------+---------------------------+----------------------+
                         |                           |
                         v                           v
                +----------------+          +----------------+
                | TransportActor |          |   ResumeStore  |
                | negotiate path |          | persisted state|
                +-------+--------+          +----------------+
                        |
          +-------------+-------------------+
          |                                 |
          v                                 v
+-----------------------+          +-----------------------+
|    L2CAPTransport     |          |     GATTTransport     |
| stream read/write API |          | fragment/reassemble   |
| backpressure + cancel |          | window + retransmit   |
+-----------+-----------+          +-----------+-----------+
            |                                  |
            +------------- CoreBluetooth -------+
                          BLECentralActor / BLEPeripheralActor
```

## Core Modules
- `Sources/GhostDropKit/BLE`: CoreBluetooth roles and capability advertisement/parsing.
- `Sources/GhostDropKit/Transport`: `GhostTransport`, L2CAP and GATT transports, sliding window.
- `Sources/GhostDropKit/Protocol`: typed frames + binary envelope codec.
- `Sources/GhostDropKit/Security`: ECDH/HKDF handshake, SAS derivation, AES-GCM context.
- `Sources/GhostDropKit/Storage`: persisted resume states and inbound file storage.
- `Sources/GhostDropKit/SessionActor.swift`: transfer/session state machine and event bus.

## Security Model
### Handshake
- Ephemeral **P-256 ECDH** key exchange.
- Shared secret expanded via **HKDF-SHA256** into encryption/auth key material.
- Transcript hash binds both peer public keys, nonces, and session id.

### SAS Verification
- 6-digit SAS is derived deterministically from transcript hash.
- Both devices display the same code.
- Transfer proceeds only when user explicitly confirms “Codes match”.

### Frame Protection
- Data chunks are encrypted with **AES.GCM** using sequence-derived nonces.
- Control frames can be wrapped as encrypted envelopes post-verification.
- `SessionCryptoContext` exposes additional HMAC support for authenticated control framing extensions.

## Transfer Protocol
- `metadata`: filename, size, mime type, SHA256, chunk size.
- `data`: sequence + payload (AES-GCM protected after verification).
- `ack`: cumulative ack + selective NACK bitmap.
- `resume`: receiver reports last confirmed sequence after reconnect.
- `complete`: sender final digest; receiver verifies final SHA256.
- `cancel`: explicit cancellation.

Receiver persists resume state in Application Support (`GhostDrop/Resume`) and continues from `lastConfirmed + 1` on reconnect.

## Demo App Features (iOS + macOS)
- Receive mode (advertising status).
- Send mode (scan + nearby list + connect).
- Pairing screen with SAS code and confirm/cancel.
- Transfer panel with progress, throughput, ETA, selected transport.
- Live log viewer and NDJSON log export.
- File picker wrappers:
  - iOS: `UIDocumentPickerViewController`
  - macOS: `NSOpenPanel`

## Running Demo Pairs
### iOS ↔ iOS
1. Launch both iOS apps.
2. Device A: Receive mode.
3. Device B: Send mode, pick Device A.
4. Verify SAS code on both devices.
5. Send file.

### macOS ↔ macOS
1. Launch both macOS apps.
2. Same steps as above.

### iOS ↔ macOS
1. Put either side in Receive mode.
2. Other side in Send mode, connect.
3. Confirm SAS and transfer.

## Limitations and BLE Constraints
- No private APIs are used.
- BLE discovery/connection behavior depends on platform radio conditions and user permissions.
- Background scan/advertise reliability is intentionally not guaranteed.
- Effective throughput varies by MTU, write-without-response availability, and link quality.
- L2CAP support can vary by peer/device state; automatic GATT fallback is required.

## Troubleshooting
- Ensure Bluetooth is enabled on both devices.
- Verify app privacy keys are present and permissions granted.
- Keep devices close and unlocked during pairing/transfer.
- If discovery is intermittent, restart scan/advertise and relaunch one peer.
- If transfers stall on GATT, reduce chunk size and window size in capabilities.

## Testing
Run unit tests:

```bash
swift test
```

Covers:
- frame codec round-trip + fuzz-ish data tests
- handshake transcript/SAS determinism
- crypto context sealing/opening
- resume persistence
- GATT sliding window ACK/NACK/timeout behavior

## Info.plist & Entitlements Notes
Add these keys for both demo apps:

- `NSBluetoothAlwaysUsageDescription`: “GhostDrop uses Bluetooth to discover nearby devices and transfer files.”
- `NSBluetoothPeripheralUsageDescription`: “GhostDrop advertises and receives nearby file transfers.”

Recommended for iOS demo UX (if needed by your file flow):
- `UISupportsDocumentBrowser` (optional, if using document browser model)

For hardened macOS targets, ensure Bluetooth capability is enabled in Signing & Capabilities if your template requires it.

## Project Layout

```text
GhostDrop/
  Package.swift
  Sources/GhostDropKit/
  Sources/GhostDropKit/BLE/
  Sources/GhostDropKit/Transport/
  Sources/GhostDropKit/Protocol/
  Sources/GhostDropKit/Security/
  Sources/GhostDropKit/Storage/
  Tests/GhostDropKitTests/
  Apps/GhostDropiOS/
  Apps/GhostDropmacOS/
  README.md
```
