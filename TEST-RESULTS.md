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

## Fan controls update (September 29, 2026)

- 39 Swift checks passed, including fan deadlines, waiting while disconnected/busy, accessory identity matching, serialization across restart, overdue recovery, manual stop, and preventing repeated uncertain Auto commands.
- 19 Python tests passed, including fan-only writes to the correct characteristic without temperature/mode writes, accepting only Auto (0) or On (100).
- ARM64 release build and strict ad-hoc code-signature verification passed. The sandbox initially blocked dsymutil; the authorized build outside the sandbox completed. The unchanged bundled helper was reused.
- Installed the updated app at the existing output location, preserving the prior build in work/Ecobee Local-before-fan-controls.app.
- Live app reconnected using its saved pairing. The fan controls were visible and enabled, and the duration picker showed 15/30/45 minutes, 1/2 hours, and Until stopped. Existing static SYSTEM heading and fan indicator remained visible.
- No live fan or HVAC command was sent during validation. Physical fan response and real-time expiration still need a live trial; timer state transitions were checked with simulated dates.
- Timers run on the Mac and require the app open, Mac awake, and local connectivity. Pending deadlines survive normal restart; uncertain Auto commands need a manual Stop / Auto retry. The thermostat’s minimum minutes per hour setting is not edited by this feature.

## Thermostat-side timer investigation (September 29, 2026)

- Added File → Inspect Fan Timer Capabilities, a read-only view of allowlisted HomeKit timer/fan fields and relevant setpoints. It does not enable timer writes, export credentials, or dump raw accessories.
- 23 Python tests passed. New coverage verifies no write calls during inspection, no unrelated names/serials in the report, status-error/write-only handling, and continued rejection of timer writes.
- Rebuilt the native ARM64 app and bundled helper; strict signature verification and bundled-helper IPC handshake passed.
- After the user approved the rebuilt app’s Keychain access, it reconnected and live read-only inspection succeeded on ECB701 firmware 4.10.40048. A readable/writable vendor hold-end field was present; standard Set/Remaining Duration fields were absent in thermostat/fan services. Fan mode was Auto and inactive. Fan-only expiration remains unverified; awaiting comparison with a user-initiated native timed fan hold. No experimental fan/hold command has been sent.

### Two-minute experimental deadline trial and pause

- User authorized shortening an existing native fan hold. Offset-bearing write initially echoed the requested deadline, then normalized four hours later; Pixel app independently confirmed the wrong time. The app/helper were fully closed across the intended deadline. This test failed due to datetime interpretation.
- Corrected source sends thermostat-local wall time without offset/suffix and waits four seconds before verification. 33 Python tests and corrected ARM64 release build/signature passed. Corrected build is in dist; the installed output app still contains the first experimental implementation. It must be replaced before another trial.
- User requested stopping before the next trial. Returned fan to Auto and verified requested/readback=0, target=1, current=0; HVAC Off/Idle and temperature settings unchanged. No Mac timer or live experiment remains active. Detailed resume checkpoint saved in the task outputs as RESUME-FAN-TIMER.md.

## Successful corrected live trial — September 29, approximately 5:48 PM

- User started a native 15-minute fan hold ending 17:58:33. The user explicitly approved applying HVAC Off for this trial. Heating/cooling thresholds stayed 20.6 / 23.3 C; the generic target changed to the heat value when entering Off.
- One corrected deadline write sent local wall time `2026-09-29T17:47:18`, with no offset or suffix. At four seconds and a later pre-expiry read, HomeKit still echoed that bare string. Therefore exact comparison with the expected normalized Q-suffixed datetime reported unconfirmed; no repeat command was sent.
- Closed the sheet, quit the app, and verified by process names that neither EcobeeMac nor HAPHelper was running by 17:46:11, before the deadline. No Mac fan timer existed.
- Reopened only after the deadline. Fresh readings at about 17:47:44 and the subsequent diagnostic read showed fanRequested=0, fanReadback=0, target fan=1 (Auto), current fan=0 (inactive), comfort indicator=0, and no usable hold-end datetime. HVAC remained Off/Idle and heat/cool thresholds unchanged.
- This is a successful independent expiration test for changing an EXISTING native fan hold on ECB701 firmware 4.10.40048. It completed well before the original 17:58:33 deadline. No fan-Off command was sent after the corrected timestamp write.
- Physical airflow was not independently measured, and the Pixel confirmation was still pending when these results were recorded. Device-reported fan operation and mode were verified.
- This does not yet validate creating a fresh fan-only hold entirely from the Mac, operating alongside an existing temperature hold, active heating/cooling, or daylight-saving transitions. Normal Run fan still uses the original Mac-managed timer.

## Fan shutdown feedback (September 30, 2026)

- 53 Swift checks passed, including immediate pending feedback, delayed readback, Auto while physically running, stale/missing readings, bounded progress, connection loss, later recovery, and failed writes.
- Stop / Auto and Mac timer expiry now show inline progress immediately. Accepted Auto commands trigger serialized read-only refreshes every two seconds while pending, for up to 30 seconds. The one-second watchdog ends progress even if a read is still in flight; the existing helper timeout bounds that read. No automatic write retries were added.
- The fan icon continues to use reported operation. Off is confirmed only with both Auto readback and an inactive/idle fan. Continuing operation and unconfirmed results receive explicit text; subsequent normal refreshes can update the result. Starting another fan run replaces the prior feedback.
- ARM64 release build and strict ad-hoc signature verification passed. Installed at the existing output location, preserving the previous bundle in work/Ecobee Local-before-fan-feedback.app. Saved pairing reconnected successfully.
- Live UI verification: with the thermostat already Off/Idle and fan off, pressed Stop / Auto and verified “Auto selected. Fan is off.” plus the checkmark and unchanged Off system mode. Layout was checked visually. A real running-to-stopped delay was not induced; delayed-response cases were tested with simulated readings. Demo UI launch was unavailable through the computer-control interface, so no demo UI result is claimed.

## Fan startup feedback (September 30, 2026)

- Generalized the shared fan feedback model to cover Run fan and Stop / Auto. Startup immediately displays “Starting fan…” with a spinner, then requires both On mode readback and active fan operation before displaying “Fan is running.”
- Both actions use the same serialized two-second read-only polling and 30-second pending limit. Missing readings, failure, timeout, and disconnect remain explicit; uncertain writes are never replayed automatically. A new opposite command replaces the old feedback; duplicate pending requests are disabled.
- 66 Swift checks passed, retaining shutdown coverage and adding startup checks for stale/missing readings, delayed activation, continued inactive operation, timeout, recovery, failure, and replacement by Stop.
- ARM64 release build and strict code-signature verification passed. Installed the updated app in the existing output location; preserved the previous build in work/Ecobee Local-before-fan-start-feedback.app.
- Live app reconnected with its saved pairing and displayed the updated fan controls. Automatic approval review blocked clicking Run fan because a real fan run requires explicit test authorization; no live fan command was sent. The user subsequently explicitly approved the brief start/stop trial described below.

### Approved live startup test (September 30, 2026)

- Started with the thermostat connected, HVAC Off/Idle, fan off, and no visible pending Mac fan timer.
- Clicked Run fan with the 15-minute selection. Observed “Starting fan…” and the “Waiting for fan status” progress indicator while the request/readback was pending.
- The next observation confirmed “Fan is running.” with a checkmark, FAN RUNNING, and the saved return-to-Auto countdown. No heating/cooling mode or temperature command was sent.
- Clicked Stop / Auto after confirming startup. Verified “Auto selected. Fan is off.”, FAN OFF, unchanged HVAC Off/Idle, and removal of the countdown. No test fan run or Mac timer remains active.
- This verifies live device-reported operation and the visible startup transition; physical airflow was not independently measured.

## DMG testing release (September 30, 2026)

- Verified GitHub origin main/HEAD as `3edebe680a0d63606eddba2d19e3db42b0c6aa78`, matching the clean local checkout. Exported that exact Git tree and rebuilt both app and helper from source in an isolated build directory, using the existing pinned Python build environment.
- 66 Swift checks and 33 Python tests passed against the exported source. ARM64 release build and strict ad-hoc signature verification passed.
- Added scripts/build-dmg.sh for repeatable DMG packaging with the app, Applications shortcut, installation instructions, and SHA-256 checksum. Existing output files are refused instead of overwritten.
- Created Ecobee-Local-0.1.0-arm64.dmg (19.7 MiB), requiring Apple Silicon and macOS 26+. Verified the disk image checksum, mounted it read-only, checked its contents, Applications symlink, bundle version/minimum OS, both executable architectures, code signature, and bundled third-party licenses. The standalone helper answered its hello handshake from the mounted image without external Python configuration. Detached the image after validation. No thermostat command or pairing was used.
- No usable Developer ID signing identity was available. This is an explicitly labeled ad-hoc-signed testing build, not notarized; normal Gatekeeper acceptance on another Mac is not claimed. No GitHub release was published.

## Cached startup and connection transition (October 3, 2026)

- Added a single versioned local snapshot tied to the saved pairing identity. Restores original reading timestamps and display/control layout while remaining disconnected; excludes sensor occupancy. Corrupt, oversized, unsupported-version, mismatched, empty, future-dated, or more-than-seven-day-old caches are rejected. Removing pairing removes the cache.
- Startup/reconnection displays a connection card with progress text and a subtle Wi-Fi pulse; Reduce Motion uses a static indicator. Last-known cards are dimmed, timestamps include their date, current fan/HVAC operation remains unknown, and all thermostat controls remain disabled until fresh authenticated data arrives. Fresh connection data resets cached control drafts. Menu-bar text explicitly shows Connecting or Offline rather than presenting a cached temperature as live.
- Saved-thermostat Bonjour discovery now returns immediately when the matching accessory resolves; first-time discovery retains its seven-second scan window. This removes an unconditional delay without bypassing HomeKit authentication. No Wi-Fi history or SSID access was added.
- 79 Swift checks passed, including 13 new cache checks. ARM64 release build and strict ad-hoc signature verification passed; unchanged helper reused. Previous installed app preserved in work/Ecobee Local-before-startup-cache.app.
- Initial updated build reconnected successfully, saved a version-1 snapshot with thermostat data and no occupancy values, and retained the existing fan run with the same end time. No thermostat-setting commands were sent. Connection completed before the UI observer captured an intermediate startup frame, so that observation does not independently verify the dimmed animation.
- Final build (including fresh-data draft reset) installed and signature verified. Its relaunch is currently waiting for macOS Keychain approval; SecurityAgent was active and the protected prompt requires user input. Final relaunch confirmation is pending.

## Expanded automated tests (October 3, 2026)

- Before this change: 79 standalone Swift core checks and 33 Python helper unit tests; no automated AppModel/native-adapter suite or measured coverage report.
- Added dependency injection for helper requests, Bonjour discovery, Keychain calls, preferences, and time. Production defaults retain the normal adapters; tests use synthetic data, isolated preference suites, and a fake helper process. Extracted draft-temperature command construction and control availability from the view into tested production logic.
- 110 Swift core checks, 106 app/adapter checks, and 65 Python unit tests passed with `bash scripts/test.sh`. Coverage reports are generated under ignored `.build-app/tests/`; no new testing dependency or full Xcode installation is required. The Python environment must already contain the pinned helper dependencies.
- App tests exercise cached startup before connection, reconnect success/failure and updated endpoints, pairing save/retry/removal failures, command serialization, disabled controls, uncertain writes without automatic retries, restored/expired fan deadlines, missing fan controls, delayed fan feedback, demo isolation, and diagnostic guards. Adapter tests cover discovery timeout/matching/deduplication/cleanup, Keychain query policy and errors, and pipe fragmentation/malformed messages/wrong IDs/oversized replies/concurrency/process exit/timeouts.
- Python tests extend validation to helper startup/shutdown, discovery/pairing/reconnect, sensor inventory and error status, command dispatch, native-deadline safeguards, JSON request processing, error redaction, license collection, and DMG packaging/no-overwrite/failure cleanup. Signing and disk-image tools are stubbed for packaging tests; those tests do not certify a real disk image or Apple developer trust.
- Found and fixed a sensor parsing inconsistency: temperature and occupancy readings carrying a HomeKit error status are now omitted rather than presented as fresh values. A regression test covers both readings.

Measured line coverage for the instrumented code:

| Scope | Line coverage |
| --- | ---: |
| Swift logic and adapters, combined | 94.26% |
| AppModel | 91.00% |
| BonjourDiscovery | 99.01% |
| HelperConnection | 95.42% |
| PairingStore adapter | 100% |
| CachedHomeSnapshot, FanFeedback, FanRun, ThermostatCommands | 100% each |
| LocalModels | 95.59% |
| Python HAP helper | 99.7% |
| Python license collector | 100% |

These are line-coverage figures, not branch coverage or a guarantee of correctness. LLVM reports the Swift figures; Python uses standard-library tracing. The native adapters are tested with fake OS dependencies, so their percentages do not establish real Keychain authorization or network behavior. The Swift denominator excludes SwiftUI rendering and app entry (`ContentView.swift`, `EcobeeMacApp.swift`); background scheduling and bundled/environment helper-path selection remain integration concerns. The Python helper's direct process-entry line is outside the unit run; its main request loop is tested. Shell build scripts and icon artwork generation have no line-coverage measurement. UI layout, animations, accessibility, actual HomeKit behavior, and signing/notarization require separate integration/manual checks.

- Rebuilt both the application and helper from current source. ARM64 architectures and strict ad-hoc signature verification passed, and the standalone bundled helper answered its hello handshake. Sandbox restrictions initially blocked `dsymutil`; the authorized build retry completed successfully.
- Shell syntax and Git whitespace checks passed. The build is in `dist/Ecobee Local.app`; the running/installed app was not replaced. No live thermostat commands or real Keychain operations were performed by this test run.
