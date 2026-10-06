# Ecobee Local for Apple Silicon

A native SwiftUI Mac app with an ARM64 local HomeKit helper. Built for a Smart Thermostat Essential; actual capability detection is performed after pairing. The bundled app requires macOS 26 or later on Apple Silicon because of its included Python runtime. This is an independent personal-use prototype, not an ecobee product.

## Download and install

**[Download Ecobee Local 0.1.0 for Apple Silicon (.dmg)](https://github.com/jeremylumanbailey/ecobee-mac-local/releases/download/v0.1.0-testing/Ecobee-Local-0.1.0-arm64.dmg)** · [Release notes and SHA-256 checksum](https://github.com/jeremylumanbailey/ecobee-mac-local/releases/tag/v0.1.0-testing)

Requires **macOS 26 or later and an Apple Silicon Mac (M1 or later)**, plus a compatible Ecobee thermostat on the same local network. Tested with Smart Thermostat Essential. The download includes the Python runtime and connection helper: **no compiling, developer tools, API key, or iPhone required**. GitHub's “Source code” archives are for developers; choose the `.dmg` asset to install the app.

1. Download and open the `.dmg`.
2. Drag **Ecobee Local.app** onto **Applications**, then eject the disk image.
3. Open the app from Applications and allow Local Network access if prompted.
4. Follow [Connect](#connect) below to pair your own thermostat using its HomeKit setup code. Your pairing stays in your Mac's Keychain.

**Testing release:** this build is ad-hoc signed and has not been notarized by Apple. macOS may block its first launch. If you trust the downloaded app, Apple's supported process may offer **System Settings → Privacy & Security → Open Anyway** after the first launch attempt. See [Apple's instructions](https://support.apple.com/102445); availability can depend on your Mac's policy. Do not disable Gatekeeper. Normal installation under standard Gatekeeper checks will require a future Developer ID signed and notarized release.

**Timed fan runs require the app to remain open and the Mac awake on the home network.** Other Ecobee models are not yet live-tested; available controls depend on the characteristics their firmware exposes.

![Screenshot](<image.png>)

## Connect

1. Open **Ecobee Local.app**. Keep your Mac and thermostat on the same home network.
2. Allow Local Network access if macOS requests it. Permissions can be reviewed under System Settings → Privacy & Security → Local Network.
3. Open HomeKit setup on the thermostat. Choose **Find my thermostat**, then **Connect** next to the discovered device.
4. Enter the eight digits displayed above the thermostat’s QR code in the app’s secure field. Do not send the code in chat.
5. The app saves pairing keys to the login Keychain and reconnects on later launches. Your Ecobee password and developer API key are not used.

No iPhone, Apple TV, HomePod, Apple Home setup, paid developer account, or Home Assistant installation is required. Your Android Ecobee app remains usable.

## Features and limits

- Current temperature, humidity, HVAC mode and operating state.
- System indicator to the left of the temperature: blue snowflake for active cooling, red flame for active heating, gray matching icon when idle, and OFF when the HVAC mode is off. Automatic mode shows the active operation or both gray icons while idle. Disconnected or unavailable status shows a dash. Draft mode edits do not affect this indicator until accepted by the thermostat.
- Fan indicator beside the indoor temperature: FAN RUNNING spins while HomeKit Current Fan State is active, and FAN OFF remains still when inactive or idle. Unavailable/disconnected readings show FAN UNKNOWN. Status normally refreshes every 20 seconds; after Run fan or Stop / Auto, read-only checks run every two seconds for up to 30 seconds. Immediate “Starting fan…” or “Stopping fan…” feedback stays visible until fresh readings confirm the requested mode and actual fan operation, or the app explains that operation is continuing or unconfirmed. The opposite action remains available between reads; a new command replaces the previous feedback. Failed writes are never retried automatically; Reduce Motion keeps the icon still.
- Heat, cool and automatic-mode temperature controls, with capability/range validation.
- Fan controls offer 15, 30, or 45 minutes, 1 or 2 hours, or On until stopped. **Stop / Auto** ends a manual fan run; the thermostat may still run the fan for heating, cooling, or its configured minimum hourly runtime. This app does not change that minimum hourly setting. Fan and resume-schedule controls appear only when matching writable Ecobee characteristics are exposed.
- Fan timers are managed by this Mac, not programmed into the thermostat. Keep the app open and the Mac awake on the home network. A pending deadline is saved in app preferences and resumed after restart; an overdue timer waits for reconnection. An attempted Auto command with an uncertain result requires manually choosing Stop / Auto again. Changing a timer replaces the previous deadline. Resume schedule does not cancel the saved fan deadline.
- Additional temperature/occupancy sensors appear when exposed by the thermostat.
- Fahrenheit/Celsius display, menu-bar reading, automatic local refresh every 20 seconds, reconnect after connection loss, and an isolated demo mode.
- Startup restores one last-known screen for the saved pairing, with dimmed readings, their original date/time, and an animated connection card. Controls remain disabled until authenticated fresh readings arrive. Offline operation shows a reconnect action. Saved-thermostat discovery proceeds as soon as a matching Bonjour result resolves instead of always waiting seven seconds; initial pairing discovery still scans the full window. Reduce Motion uses a static connection indicator.
- Temperature edits require clicking Apply changes. Failed or timed-out writes are not automatically retried.
- Temperature holds use the thermostat’s own behavior/preferences. Schedule editing, vacations, eco+ configuration, remote cloud control and historical charts are not implemented.
- Works while the Mac is awake and the app is running. The thermostat continues its own schedule while the app is closed or the Mac sleeps.
- One paired thermostat per app installation; all thermostat services and sensors exposed by it can be displayed.

## Inspecting thermostat-side timers

Use **File → Inspect Fan Timer Capabilities…** while connected to read the thermostat’s fan controls, Ecobee hold deadline, and standard duration capabilities. Read again can compare these values before/after a fan hold set on the thermostat or official app. This inspection sends no setting changes and exports no pairing credentials, serial numbers, network addresses, or room names. A writable hold deadline is only a candidate: it can also govern climate holds, so its presence does not prove independent fan timing. Normal fan controls still use Mac-managed timers. The inspection sheet also includes an explicitly labeled experimental two-minute deadline trial, restricted to the inspected Essential firmware, an already-running native fan hold with 3 minutes–6 hours left, HVAC Off/Idle, and no Mac timer. It changes only the existing hold deadline and checks readback; this is a development test, not verified general fan scheduling.

## Troubleshooting

If discovery is empty, check the local network permission, matching home network, guest/client isolation, VPN routing, and the thermostat’s HomeKit setup screen. A thermostat paired with another HomeKit controller is shown as already paired; do not reset it unless you intend to remove that existing integration.

For pairing errors, start discovery again and generate a fresh code on the thermostat. Keep the app open if Keychain saving fails and use Retry saving pairing. Removing pairing contacts the thermostat before deleting local keys; it requires the thermostat to be reachable.

Pairing data is stored in a non-synchronizing, device-only Keychain item (`local.ecobee.mac.homekit.v1`). The Python helper receives keys over private process pipes, holds them in memory, and writes no pairing files. A pending fan timer stores its deadline and accessory/service identifiers in local app preferences, without pairing keys. One startup snapshot is also stored in local preferences, tied to the pairing identity and overwritten on successful reads; it contains display readings and control metadata but no pairing keys, network history, or sensor occupancy history. It is discarded at startup if more than seven days old, invalid, or mismatched, and removed when pairing is removed. A cached screen never establishes connectivity or authorizes commands. No cloud service, analytics, or local web server is used. Rebuilding an ad-hoc-signed app can cause macOS to request Keychain access again.

## Build and test

The delivered app bundles its own Python interpreter and dependencies; Python is needed only to rebuild it. Native UI and helper executables are ARM64. No Rosetta is required. The package uses aiohomekit 4.0.1 and PyInstaller 6.22.3, pinned with transitive versions in helper/requirements.lock. Third-party notices are bundled under Contents/Resources/ThirdPartyLicenses.

Prerequisites for rebuilding: Apple command-line Swift tools, Python 3.14, and internet access for the pinned PyPI dependencies. Full Xcode is optional for this local app. To use Xcode, complete its first-run license/setup yourself first.

```sh
bash scripts/build-app.sh
bash scripts/test.sh
```

Run these commands from the repository root. The build produces `dist/Ecobee Local.app`; temporary build files and its Python environment stay under `.build-app/`. The test runner uses that Python environment, or `ECOBEE_TEST_PYTHON` / `ECOBEE_BUILD_PYTHON` if set. It adds no test dependencies. You can run tests without rebuilding the app once the pinned helper dependencies are installed.

The Swift checks are a standalone executable so they also run with Command Line Tools, which do not include XCTest. `ECOBEE_BUILD_ROOT`, `ECOBEE_BUILD_PYTHON`, and `ECOBEE_APP_OUTPUT` can customize build paths. The build prefers the installed macOS 26.5 SDK; `ECOBEE_SDK` overrides it. This avoids a missing SwiftUI macro plugin in the installed macOS 27 Command Line Tools. For `swift run EcobeeMac`, set `ECOBEE_HELPER_PYTHON` and `ECOBEE_HELPER_SCRIPT` to absolute paths for the helper runtime and source file.

### Automated test coverage

`bash scripts/test.sh` runs the LocalCore checks, app/adapter checks, and Python unit tests, and exits nonzero on failure. Swift tests use production sources compiled with coverage instrumentation. Reports are written beneath the ignored `.build-app/tests/` directory; `latest-coverage-path.txt` identifies the most recent successful run. Open its `swift-html/index.html` for line-by-line Swift coverage, `swift-summary.txt` for totals, and `python/` for annotated Python source (`>>>>>>` marks unexecuted lines). Python uses standard-library line tracing and prints a summary in `python-summary.txt`.

The tests cover temperature commands, cached startup, control availability, pairing persistence failures, reconnects, fan deadlines and feedback, Bonjour discovery, pipe protocol failures, helper command validation, and packaging safeguards. Test fixtures replace Keychain, discovery, thermostat communication, clock, and app preferences. Pipe tests run a synthetic helper; packaging tests stub signing and disk-image tools. No test pairs with or sends commands to a real thermostat, accesses saved pairing keys, or changes normal app preferences.

Coverage is **not 100% of the entire application**. The Swift report covers `LocalCore`, `AppModel`, and the native adapters; it excludes `ContentView.swift` and `EcobeeMacApp.swift` (SwiftUI rendering and app entry). Draft-temperature logic and control gating have been extracted into tested production code. Background task scheduling, actual Keychain authorization, real Bonjour/HomeKit communication, UI animations/accessibility, and Apple signing/notarization still need integration or manual validation. The build script is checked by building the ARM64 app; shell scripts do not have line-coverage percentages. See `TEST-RESULTS.md` for measured results and remaining limitations.

This build is locally ad-hoc signed, not notarized for public distribution. Developer ID signing/notarization is separate from HomeKit pairing and is not needed for the local build workflow.

## Build a downloadable DMG

```sh
bash scripts/build-dmg.sh
```

This rebuilds the standalone ARM64 app, packages it with an Applications shortcut and installation instructions, verifies the compressed disk image, and writes `dist/Ecobee-Local-0.1.0-arm64.dmg` plus a `.sha256` checksum. The version comes from `Info.plist`. The current bundled runtime requires **macOS 26 or later and Apple Silicon (M1 or later)**. Recipients do not need Python or developer tools.

To package a previously verified bundle without rebuilding, set `ECOBEE_DMG_APP` to its path. `ECOBEE_DMG_OUTPUT` overrides the output filename; existing output files are never overwritten. The script currently produces an **ad-hoc-signed testing build** and labels it accordingly. It does not sign with Developer ID, notarize, publish a GitHub release, or include local pairing data.

A DMG is an installation container; it does not establish developer trust. For a public download that opens under normal Gatekeeper checks, configure a Developer ID Application certificate, sign the application and nested helper/runtime code appropriately, submit to Apple's notary service, and staple the accepted ticket before distributing. See [Apple's distribution guidance](https://developer.apple.com/macos/distribution/). Keep signing keys and notarization credentials outside the repository.

## Sources

- [Ecobee Essential HomeKit support](https://www.ecobee.com/en-us/smart-thermostats/smart-thermostat-essential/)
- [aiohomekit, the local protocol implementation](https://github.com/Jc2k/aiohomekit)
- [Local HomeKit pairing without Apple hardware](https://www.home-assistant.io/integrations/homekit_controller/)

## Validation status

The user successfully paired the app with their Smart Thermostat Essential and reported that it appeared in the app. See TEST-RESULTS.md for performed checks and remaining live validation.

## Repository contents

Commit `Sources/`, `helper/` (including `requirements.lock`), `Tests/`, `scripts/`, `Package.swift`, `Info.plist`, `AppIcon.icns`, `.gitignore`, and the Markdown documentation. Keep `Package.resolved` under version control if Swift dependencies are added later. The icon is intentionally included so a clean checkout builds without first generating artwork.

The `.gitignore` excludes compiled apps, build directories, Python environments and caches, local VS Code/JetBrains settings, Xcode user state, temporary icon renders, logs, macOS metadata, pairing/credential exports, signing keys, and diagnostic/network captures. Credentials belong in Keychain; never add real pairing data or thermostat codes to source or test fixtures. Public environment templates such as `.env.example` remain eligible for version control and must contain placeholders only. Ignore rules do not detect secrets embedded in source files or remove already tracked files; review the staged diff before each commit.
