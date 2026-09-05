<div align="center">

# Hermes Mobile

**The native iPhone companion for Hermes Agent Desktop.**

Continue runs, talk to every configured agent, approve tools, and inspect shared skills or memory from your phone. Hermes Mobile is a thin node on the existing Hermes gateway—it does not host a second agent or backend.

[![iOS 18+](https://img.shields.io/badge/iOS-18%2B-000000?logo=apple&logoColor=white)](#build-from-source)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](LICENSE)

</div>

> [!IMPORTANT]
> Hermes Mobile is in pre-release validation. The native gateway client and Desktop pairing flow are implemented, but a physical-iPhone pairing pass and signed TestFlight build are still required before a public release.

## What it does

- Pairs from **Hermes Desktop → Settings → Gateways → Hermes mobile companion**.
- Discovers every profile configured on the connected Hermes gateway.
- Resumes the latest session for any agent or starts a new run.
- Streams replies and tool activity over the gateway's native `/api/ws` protocol.
- Steers or stops a run without remounting the transcript.
- Shows tool approvals and sends explicit allow or deny decisions.
- Opens Preview, Approvals, Skills, Memory, Updates, and Voice as focused sheets—not permanent tabs.
- Queues an unsent message when the gateway is unreachable and retries only when requested.
- Stores the gateway URL and token in the iPhone Keychain.
- Supports dark/light appearance and a custom accent-color picker; Hermes Gold is the default.

## Product shape

The phone is conversation-shaped rather than a reduced desktop dashboard:

1. **Pairing** appears only before a gateway is configured.
2. **Roster** is home: real Hermes profiles and their latest work appear as conversations.
3. **Run** is the work surface: transcript, compact tool receipts, live status, and the composer.
4. **Sheets** hold approvals, preview, skills, memory, updates, and talk mode while preserving the live run.

## Architecture

```text
iPhone Hermes Mobile
        │
        │ native authenticated WebSocket /api/ws
        ▼
Existing Hermes gateway / mesh
        │
        ├── all configured agent profiles
        ├── existing sessions and live runs
        ├── approvals
        ├── skills
        └── memory
```

There is no mobile-only server, duplicate listener, relay, or duplicate agent. QR pairing encodes the gateway's configured private HTTPS address plus a freshly issued local gateway token. The code is hidden after two minutes and is never printed in Desktop logs.

## Pairing

1. Start Hermes Desktop on macOS or Windows and connect it to the gateway that owns your agents.
2. Make that gateway reachable from the phone through private HTTPS, such as Tailscale Serve, or use an always-on remote/cloud gateway.
3. In Desktop, open **Settings → Gateways → Hermes mobile companion** and select **Show pairing code**.
4. Open Hermes Mobile and scan the code. The phone verifies `gateway.ready` before saving the connection.

A gateway hosted only on a laptop cannot be reached while that laptop is powered off or fully asleep. For all-day mobile control, run the same Hermes gateway on an always-on machine or hosted environment; the phone still connects to that one existing gateway.

## Build from source

Requirements:

- macOS with Xcode 26 or newer
- iOS 18 or newer simulator/device
- a Hermes Desktop gateway for live pairing

```zsh
git clone https://github.com/BkashJEE/hermex-app.git
cd hermex-app
open HermesMobile.xcodeproj
```

Or validate from the command line:

```zsh
xcodebuild test \
  -project HermesMobile.xcodeproj \
  -scheme HermesMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

The checked-in signing defaults are for CI/source validation. Configure your own Apple Developer team in `Config/Local.xcconfig` for a physical device or TestFlight build; that file is gitignored.

## Security

- Pairing refuses plain HTTP, loopback public addresses, embedded URL credentials, incomplete codes, and one-time OAuth tickets.
- Secrets are stored in Keychain and omitted from visible UI, logs, tests, screenshots, and Git history.
- The Desktop pairing panel does not create a public gateway. You choose and control the private HTTPS route.
- Tool approvals show the exact command and require an explicit response; the app does not optimistically mark approval complete.

See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## Status and verification

The iOS branch is validated in GitHub Actions on macOS with the full XCTest suite. Desktop pairing has focused behavior tests, TypeScript checks, lint, a production renderer build, and an isolated Windows runtime smoke test. Release readiness still requires the physical-device and signed-distribution checks called out above.

## Acknowledgements

Hermes Mobile began from the open-source HermeX SwiftUI client and retains its MIT license and copyright notices. The product identity, roster-first interaction model, Hermes Desktop gateway transport, pairing flow, approval surfaces, and black-and-gold mobile design in this fork are Hermes-specific.

## License

[MIT](LICENSE)
