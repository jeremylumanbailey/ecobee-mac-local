# Validation results

Tested on the user's Apple Silicon Mac, macOS 26.6.2.

## Passed

- Release build using Swift 6.4 with the installed macOS 26.5 SDK.
- Main application and bundled HAP helper verified as ARM64 Mach-O executables.
- Ad-hoc code signature verified with `codesign --verify --deep --strict`.
- Bundled helper launched without an external Python installation and answered its JSON IPC handshake.
- 16 Python tests: accessory parsing, capability and address validation, temperature bounds and increments, mode support, error handling, no automatic write retries, and returning pairing keys before optional reads.
- 9 Swift checks: temperature conversion, characteristic step quantization, missing/invalid readings, sample firmware labeling, and mode capabilities.
- Native UI launched successfully. Demo tested: temperature edit and Apply, switching display units, changing mode, and Discard restoring the previous mode. No live thermostat settings were changed.
- macOS Bonjour independently detected an unpaired Ecobee thermostat (model ECB701).

## Live pairing

The user subsequently confirmed successful pairing with their Smart Thermostat Essential and reported that it appeared in the local app. This supersedes the earlier temporary discovery blocker. The cause of that temporary discovery failure was not established.

Detailed reading accuracy, the firmware's exposed optional controls, real setting changes, and restoring the Keychain pairing after relaunch still require explicit live verification. The pairing confirmation is user-reported; automated tests used fixtures and did not change the real thermostat.

## Fan indicator update (September 20, 2026)

- 18 Python tests passed, including current fan state parsing independently of requested fan mode and handling unavailable/error readings.
- 15 Swift checks passed, including active, inactive, idle, missing, and invalid fan states.
- The indicator reads HomeKit Current Fan State (`AF`): active (2) spins, inactive (0) and idle (1) remain still. Unknown/disconnected status does not claim the fan is off. No HVAC command is sent by the indicator.
- Animation respects the macOS Reduce Motion preference.
- Updated ARM64 app and helper built successfully; strict code-signature verification and bundled-helper IPC smoke test passed.
- The rebuilt app was installed at the existing output location and launched. Live visual verification is pending macOS Keychain authorization; SecurityAgent was active and the protected prompt requires the user's input. No thermostat settings were changed during this update.

## System indicator update (September 20, 2026)

- 28 Swift checks passed, covering heating/cooling active and idle states, Off, Auto, missing readings, and disconnected status.
- Release ARM64 build and strict code-signature verification passed. The updated app was installed in the existing output location.
- Added the left-side symbol using confirmed thermostat mode/operating state, with blue cooling, red heating, gray idle icons, and OFF. Automatic idle shows both gray icons; unavailable/disconnected status shows a dash.
- Live visual verification is pending authorization of the rebuilt app's Keychain access. No thermostat settings were changed.

## Build notes

The installed macOS 27 SDK requires a SwiftUI macro plugin missing from Command Line Tools. The included build script selects the installed macOS 26.5 SDK, which compiled successfully. Harmless linker warnings mention unused Command Line Tools framework search paths. Full Xcode first-run setup was not required.

The bundled Python runtime has a macOS 26 minimum deployment version; the app's Info.plist and README reflect this. No additional user installations are needed to run the delivered bundle.
