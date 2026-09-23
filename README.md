# Ecobee Local for Apple Silicon

A native SwiftUI Mac app with an ARM64 local HomeKit helper. Built for a Smart Thermostat Essential; actual capability detection is performed after pairing. The bundled app requires macOS 26 or later on Apple Silicon because of its included Python runtime. This is an independent personal-use prototype, not an ecobee product.

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
- Fan indicator beside the indoor temperature: FAN RUNNING spins while HomeKit Current Fan State is active, and FAN OFF remains still when inactive or idle. Unavailable/disconnected readings show FAN UNKNOWN. Status follows the existing 20-second refresh; Reduce Motion keeps the icon still.
- Heat, cool and automatic-mode temperature controls, with capability/range validation.
- Fan and resume-schedule controls appear only when matching writable Ecobee characteristics are exposed. Their availability on firmware 4.10.4.48 requires a live check.
- Additional temperature/occupancy sensors appear when exposed by the thermostat.
- Fahrenheit/Celsius display, menu-bar reading, automatic local refresh every 20 seconds, reconnect after connection loss, and an isolated demo mode.
- Temperature edits require clicking Apply changes. Failed or timed-out writes are not automatically retried.
- Temperature holds use the thermostat’s own behavior/preferences. Schedule editing, vacations, eco+ configuration, remote cloud control and historical charts are not implemented.
- Works while the Mac is awake and the app is running. The thermostat continues its own schedule while the app is closed or the Mac sleeps.
- One paired thermostat per app installation; all thermostat services and sensors exposed by it can be displayed.

## Troubleshooting

If discovery is empty, check the local network permission, matching home network, guest/client isolation, VPN routing, and the thermostat’s HomeKit setup screen. A thermostat paired with another HomeKit controller is shown as already paired; do not reset it unless you intend to remove that existing integration.

For pairing errors, start discovery again and generate a fresh code on the thermostat. Keep the app open if Keychain saving fails and use Retry saving pairing. Removing pairing contacts the thermostat before deleting local keys; it requires the thermostat to be reachable.

Pairing data is stored in a non-synchronizing, device-only Keychain item (`local.ecobee.mac.homekit.v1`). The Python helper receives keys over private process pipes, holds them in memory, and writes no pairing files. No cloud service, analytics, or local web server is used. Rebuilding an ad-hoc-signed app can cause macOS to request Keychain access again.

## Build and test

The delivered app bundles its own Python interpreter and dependencies; Python is needed only to rebuild it. Native UI and helper executables are ARM64. No Rosetta is required. The package uses aiohomekit 4.0.1 and PyInstaller 6.22.3, pinned with transitive versions in helper/requirements.lock. Third-party notices are bundled under Contents/Resources/ThirdPartyLicenses.

Prerequisites for rebuilding: Apple command-line Swift tools, Python 3.14, and internet access for the pinned PyPI dependencies. Full Xcode is optional for this local app. To use Xcode, complete its first-run license/setup yourself first.

```sh
bash scripts/build-app.sh
swift run LocalCoreChecks
.build-app/venv/bin/python -m unittest discover -s Tests/HelperTests -v
```

Run these commands from the repository root. The build produces `dist/Ecobee Local.app`; temporary build files and its Python environment stay under `.build-app/`. If using `ECOBEE_BUILD_PYTHON`, run the Python tests with that interpreter instead. For the same SDK used by the build script, pass `--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` to `swift run` on Macs with that SDK installed.

The Swift checks are a standalone executable so they also run with Command Line Tools, which do not include XCTest. `ECOBEE_BUILD_ROOT`, `ECOBEE_BUILD_PYTHON`, and `ECOBEE_APP_OUTPUT` can customize build paths. The build prefers the installed macOS 26.5 SDK; `ECOBEE_SDK` overrides it. This avoids a missing SwiftUI macro plugin in the installed macOS 27 Command Line Tools. For `swift run EcobeeMac`, set `ECOBEE_HELPER_PYTHON` and `ECOBEE_HELPER_SCRIPT` to absolute paths for the helper runtime and source file.

This build is locally ad-hoc signed, not notarized for public distribution. Developer ID signing/notarization is separate from HomeKit pairing and is not needed for the local build workflow.

## Sources

- [Ecobee Essential HomeKit support](https://www.ecobee.com/en-us/smart-thermostats/smart-thermostat-essential/)
- [aiohomekit, the local protocol implementation](https://github.com/Jc2k/aiohomekit)
- [Local HomeKit pairing without Apple hardware](https://www.home-assistant.io/integrations/homekit_controller/)

## Validation status

The user successfully paired the app with their Smart Thermostat Essential and reported that it appeared in the app. See TEST-RESULTS.md for performed checks and remaining live validation.

## Repository contents

Commit `Sources/`, `helper/` (including `requirements.lock`), `Tests/`, `scripts/`, `Package.swift`, `Info.plist`, `AppIcon.icns`, `.gitignore`, and the Markdown documentation. Keep `Package.resolved` under version control if Swift dependencies are added later. The icon is intentionally included so a clean checkout builds without first generating artwork.

The `.gitignore` excludes compiled apps, build directories, Python environments and caches, local VS Code/JetBrains settings, Xcode user state, temporary icon renders, logs, macOS metadata, pairing/credential exports, signing keys, and diagnostic/network captures. Credentials belong in Keychain; never add real pairing data or thermostat codes to source or test fixtures. Public environment templates such as `.env.example` remain eligible for version control and must contain placeholders only. Ignore rules do not detect secrets embedded in source files or remove already tracked files; review the staged diff before each commit.
