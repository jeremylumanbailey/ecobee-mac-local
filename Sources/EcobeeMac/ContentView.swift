import SwiftUI
import LocalCore

private let mint = Color(red: 0.58, green: 0.87, blue: 0.71)
private let canvas = Color(red: 0.075, green: 0.095, blue: 0.085)
private let panel = Color(red: 0.12, green: 0.15, blue: 0.13)

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State<Bool> private var confirmUnpair = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(.white.opacity(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if model.demo {
                        banner("Demo home · All readings and changes are simulated.", icon: "play.rectangle", color: mint)
                    }
                    if let error = model.error {
                        banner(error, icon: "exclamationmark.triangle", color: .orange)
                    }
                    if let notice = model.notice { banner(notice, icon: "checkmark.circle", color: mint) }
                    if model.hasUnsavedPairing {
                        Button("Retry saving pairing to Keychain") { model.retrySave() }
                            .buttonStyle(.borderedProminent).tint(.orange)
                    }
                    if model.isConnecting || (model.snapshot != nil && !model.demo && !model.connected) {
                        connectionStatus
                    }
                    if let snapshot = model.snapshot {
                        if snapshot.thermostats.isEmpty {
                            banner("Pairing succeeded, but this device exposes no thermostat service.", icon: "thermometer", color: .orange)
                        }
                        ForEach(snapshot.thermostats) { thermostat in
                            ThermostatCard(thermostat: thermostat)
                                .opacity(model.connected || model.demo ? 1 : 0.5)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.connected)
                        }
                        if !snapshot.sensors.isEmpty { sensorSection(snapshot.sensors) }
                        HStack {
                            Text(snapshot.model)
                            Spacer()
                            Text("Firmware \(snapshot.firmware)")
                        }.font(.caption).foregroundStyle(.secondary)
                    } else if model.isConnecting {
                        // The connection card above is the startup screen until a cache or live data is available.
                        EmptyView()
                    } else if model.paired {
                        VStack(alignment: .leading, spacing: 16) {
                            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(mint)
                            Text("Your pairing is saved.").font(.title2.bold())
                            Text("Reconnect when the thermostat and this Mac are on the same local network.").foregroundStyle(.secondary)
                            Button("Reconnect") { Task { await model.reconnect() } }
                                .buttonStyle(.borderedProminent).tint(mint).disabled(model.busy)
                        }.card()
                    } else { PairingView() }
                }.padding(34)
            }
        }
        .background(canvas)
        .preferredColorScheme(.dark)
        .tint(mint)
        .sheet(isPresented: $model.showTimerDiagnostics) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Fan timer capabilities").font(.title2.bold())
                Text("Read-only inspection. A writable hold deadline does not confirm support for a fan-only timer. Read again does not change settings. The experimental test button changes the existing fan-hold deadline.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                if let message = model.timerTrialMessage {
                    Text(message).font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    Text(model.timerDiagnostics ?? "No report available.")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Read again") { Task { await model.inspectFanTimer() } }
                        .disabled(model.busy || !model.connected)
                    Button("Test 2-minute thermostat timer") { Task { await model.testFanDeadline() } }
                        .disabled(model.busy || !model.connected || model.fanRun != nil)
                        .help("Experimental: shortens an existing native fan-only hold. Requires heating/cooling Off. No Mac timer is created.")
                    Spacer()
                    Button("Done") { model.showTimerDiagnostics = false }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 700, height: 600)
        }
        .alert("Remove this Mac’s pairing?", isPresented: $confirmUnpair) {
            Button("Cancel", role: .cancel) {}
            Button("Remove pairing", role: .destructive) { Task { await model.unpair() } }
        } message: {
            Text("This removes this app’s HomeKit pairing from the thermostat and its saved keys from your Mac. You will need the thermostat’s pairing code to reconnect.")
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(systemName: "leaf.fill").font(.title2).foregroundStyle(mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ecobee local").font(.headline)
                    Text("FOR YOUR MAC").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                }
            }.padding(.top, 18)
            Label("My thermostat", systemImage: "house.fill")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(mint)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Label("Close to home.", systemImage: "wifi").font(.headline)
                Text("Direct communication over your home network.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label("Pairing saved in Keychain", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Picker("Temperature", selection: $model.unitRaw) {
                ForEach(DisplayUnit.allCases) { unit in Text(unit.symbol).tag(unit.rawValue) }
            }.pickerStyle(.segmented).accessibilityLabel("Temperature display unit")
            if model.demo {
                Button("Exit demo") { model.exitDemo() }.disabled(model.busy)
            } else if model.paired {
                Button("Remove pairing…") { confirmUnpair = true }
                    .disabled(model.busy || !model.connected || model.hasUnsavedPairing)
            }
            Text("Independent app · Not made by ecobee")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }.padding(22).frame(width: 230).background(.black.opacity(0.12))
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.snapshot == nil ? "WELCOME HOME" : "HOME CLIMATE")
                    .font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(mint)
                Text(model.snapshot?.name ?? "Comfort, closer.")
                    .font(.system(size: 29, weight: .semibold, design: .rounded))
                if let updated = model.lastUpdated {
                    HStack(spacing: 5) {
                        Circle().fill(model.connected || model.demo ? mint : .orange).frame(width: 5, height: 5)
                        Text(model.demo ? "Sample home" : model.connected ? "Local connection" : model.isConnecting ? "Connecting…" : "Disconnected")
                        Text("· \(model.connected || model.demo ? "Checked" : "Last updated") \(updated.formatted(date: model.connected || model.demo ? .omitted : .abbreviated, time: .shortened))")
                    }.font(.caption).foregroundStyle(.secondary)
                } else { Text("Your thermostat, one click away.").foregroundStyle(.secondary) }
            }
            Spacer()
            if model.busy && !model.isConnecting { ProgressView().controlSize(.small).padding(.top, 10).accessibilityLabel("Working") }
            if model.snapshot != nil {
                Button {
                    Task { if model.connected || model.demo { await model.refresh() } else { await model.reconnect() } }
                } label: { Image(systemName: "arrow.clockwise").padding(5) }
                    .help("Refresh thermostat").accessibilityLabel("Refresh thermostat").disabled(model.busy)
            }
        }
    }
    private var connectionStatus: some View {
        HStack(spacing: 16) {
            Image(systemName: model.isConnecting ? "wifi" : "wifi.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(model.isConnecting ? mint : .orange)
                .symbolEffect(.pulse, options: .repeating, isActive: model.isConnecting && !reduceMotion)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.isConnecting ? "Connecting to your Ecobee…" : "Thermostat is offline")
                    .font(.headline)
                Text(model.connectionStage ?? "Reconnect when your thermostat is reachable on the local network.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(model.snapshot == nil
                     ? "Your controls will appear once fresh readings arrive."
                     : "Last known readings are dimmed. Controls unlock when fresh readings arrive.")
                    .font(.caption).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if model.isConnecting && !reduceMotion {
                ProgressView().controlSize(.small).accessibilityLabel("Connecting to thermostat")
            } else if !model.isConnecting {
                Button("Reconnect") { Task { await model.reconnect() } }.disabled(model.busy)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(mint.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
    private func banner(_ text: String, icon: String, color: Color) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon) }
            .font(.callout).foregroundStyle(color).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
    private func sensorSection(_ sensors: [RoomSensor]) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Around the house").font(.headline)
            ForEach(sensors) { sensor in
                HStack {
                    Image(systemName: "sensor.fill").foregroundStyle(mint)
                    VStack(alignment: .leading) {
                        Text(sensor.name)
                        if model.connected || model.demo, let occupied = sensor.occupied { Text(occupied ? "Occupancy detected" : "No occupancy detected").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(model.unit.text(sensor.temperature)).font(.title3.monospacedDigit())
                }
            }
        }.card().opacity(model.connected || model.demo ? 1 : 0.5)
    }
}

private struct PairingView: View {
    @EnvironmentObject var model: AppModel
    @State<String> private var pin = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: "thermometer.medium").font(.system(size: 34)).foregroundStyle(mint)
                Spacer()
                Text("NO CLOUD LOGIN").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(mint)
            }
            Text(model.pairingReady ? "A one-time introduction." : "Connect your Ecobee")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            if model.pairingReady {
                Text("Look at your thermostat for its eight-digit HomeKit code. Enter it here to securely pair this Mac.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("HomeKit code · 123-45-678", text: $pin)
                    .textFieldStyle(.roundedBorder).font(.title3.monospaced()).frame(maxWidth: 310)
                    .onSubmit { pair() }.accessibilityLabel("HomeKit pairing code")
                HStack {
                    Button("Pair securely") { pair() }.buttonStyle(.borderedProminent)
                        .disabled(model.busy || pin.filter(\.isNumber).count != 8)
                    Button("Start again") { pin = ""; Task { await model.discover() } }.disabled(model.busy)
                }
                Text("The pairing session lasts about three minutes. Your code is never saved.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Keep this Mac and your Smart Thermostat Essential on the same home network. Open the thermostat’s HomeKit settings if discovery needs help.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button(model.didSearch ? "Search again" : "Find my thermostat") { Task { await model.discover() } }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
                    Button("Explore demo") { model.showDemo() }.controlSize(.large).disabled(model.busy)
                }
                ForEach(model.devices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name).font(.headline)
                            Text("\(device.model) · \(device.available ? "Ready to pair" : "Already paired")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Connect") { Task { await model.beginPairing(device) } }
                            .disabled(model.busy || !device.available)
                    }.padding(14).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }
                if model.didSearch && model.devices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No thermostat found yet.").font(.headline)
                        Text("Check that both devices use the same home network rather than a guest network. If macOS asks, allow Local Network access. A VPN may prevent discovery.")
                        Text("In System Settings → Privacy & Security → Local Network, check Ecobee Local. Then search again.")
                    }.font(.callout).foregroundStyle(.secondary)
                }
            }
            Divider()
            Label("No iPhone, Ecobee API key, or home hub required.", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
        }.card()
    }
    private func pair() {
        let code = pin; pin = ""
        Task { await model.finishPairing(pin: code) }
    }
}

private struct ThermostatCard: View {
    @EnvironmentObject var model: AppModel
    let thermostat: LocalThermostat
    @State<Int> private var mode = 0
    @State<Double> private var target = 22.0
    @State<Double> private var heat = 20.0
    @State<Double> private var cool = 24.0
    @State<Bool> private var edited = false
    var canControl: Bool { !model.busy && (model.connected || model.demo) && !model.hasUnsavedPairing }
    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Text(thermostat.name).font(.headline)
                Spacer()
                Label(model.connected || model.demo ? thermostat.stateName : "Last known readings", systemImage: model.connected || model.demo ? (thermostat.state == 1 ? "flame.fill" : thermostat.state == 2 ? "snowflake" : "leaf") : "clock")
                    .font(.caption.weight(.medium)).foregroundStyle(mint)
            }
            HStack(alignment: .top, spacing: 16) {
              SystemStatusView(status: thermostat.systemIndicator(isCurrent: model.connected || model.demo))
                .frame(width: 130)
              VStack(spacing: 5) {
                Text("INDOOR TEMPERATURE").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                Text(model.unit.text(thermostat.current))
                    .font(.system(size: 82, weight: .light, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityLabel("\(model.connected || model.demo ? "Indoor temperature" : "Last known indoor temperature") \(model.unit.text(thermostat.current)) \(model.unit.symbol)")
                HStack(spacing: 16) {
                    if let humidity = thermostat.humidity {
                        Label("\(Int(humidity))% humidity", systemImage: "humidity").foregroundStyle(.secondary)
                    }
                    Text(model.unit.symbol).foregroundStyle(mint)
                }.font(.callout)
              }.frame(maxWidth: .infinity)
              FanStatusView(running: model.connected || model.demo ? thermostat.fanRunning : nil)
                .frame(width: 130)
            }.padding(.vertical, 8)
            if !thermostat.allowedModes.isEmpty {
                Picker("System mode", selection: $mode) {
                    ForEach(thermostat.allowedModes, id: \.self) { value in
                        Text(LocalThermostat.modeNames[value] ?? "Unknown").tag(value)
                    }
                }.pickerStyle(.segmented).disabled(!canControl)
                    .onChange(of: mode) { _, value in edited = value != Int(thermostat.mode ?? 0) || edited }
            }
            if mode == 3 {
                HStack(spacing: 14) {
                    if thermostat.fields["heat"] != nil { temperatureControl("Heat to", field: "heat", value: $heat, color: .orange) }
                    if thermostat.fields["cool"] != nil { temperatureControl("Cool to", field: "cool", value: $cool, color: .cyan) }
                }
            } else if mode != 0, thermostat.fields["target"] != nil {
                temperatureControl("Target temperature", field: "target", value: $target, color: mint)
            }
            HStack {
                if thermostat.fields["resume"] != nil {
                    Button("Resume schedule") { Task { await model.write(["resume": true], thermostat: thermostat) }; edited = false }
                        .disabled(!canControl)
                }
                Spacer()
                if edited { Button("Discard") { sync() }.disabled(model.busy) }
                Button("Apply changes") { apply() }
                    .buttonStyle(.borderedProminent).disabled(!canControl || !edited)
            }
            Text("Temperature changes create a hold. Its duration follows your thermostat’s settings. Controls shown depend on what your Ecobee exposes locally.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if thermostat.fields["fan"] != nil {
                Divider()
                FanControlsView(thermostat: thermostat, canControl: canControl)
            }
        }.card()
        .onAppear { sync() }
        .onChange(of: model.lastUpdated) { _, _ in if !edited { sync() } }
        .onChange(of: model.connected) { _, connected in
            if connected { sync() } else { edited = false }
        }
    }
    private func temperatureControl(_ title: String, field: String, value: Binding<Double>, color: Color) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.callout).foregroundStyle(color)
            HStack {
                Button { adjust(value, by: -1, field: field) } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Decrease \(title)")
                Spacer()
                Text(model.unit.text(value.wrappedValue)).font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                Spacer()
                Button { adjust(value, by: 1, field: field) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Increase \(title)")
            }.buttonStyle(.bordered).disabled(!canControl)
        }.padding(16).frame(maxWidth: .infinity).background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
    }
    private func adjust(_ binding: Binding<Double>, by direction: Double, field: String) {
        guard let meta = thermostat.fields[field] else { return }
        let display = model.unit.fromCelsius(binding.wrappedValue)
        let increment = model.unit == .celsius ? 0.5 : 1.0
        let raw = model.unit.toCelsius(display + direction * increment)
        binding.wrappedValue = min(max(meta.quantized(raw), max(meta.minimum ?? 4, 4)), min(meta.maximum ?? 35, 35))
        edited = true
    }
    private func sync() {
        let latest = model.snapshot?.thermostats.first { $0.id == thermostat.id } ?? thermostat
        mode = Int(latest.mode ?? 0); target = latest.target ?? 22
        heat = latest.heat ?? 20; cool = latest.cool ?? 24; edited = false
    }
    private func apply() {
        var changes: [String: Any] = [:]
        if Double(mode) != thermostat.mode { changes["mode"] = Double(mode) }
        if mode == 3 {
            if let meta = thermostat.fields["heat"], heat != thermostat.heat { changes["heat"] = meta.quantized(heat) }
            if let meta = thermostat.fields["cool"], cool != thermostat.cool { changes["cool"] = meta.quantized(cool) }
        } else if mode != 0, let meta = thermostat.fields["target"], target != thermostat.target { changes["target"] = meta.quantized(target) }
        guard !changes.isEmpty else { edited = false; return }
        if mode == 3 && heat >= cool { model.error = "The heating target must be below the cooling target."; return }
        Task {
            await model.write(changes, thermostat: thermostat)
            if model.error == nil { edited = false; sync() }
        }
    }
}

private struct FanControlsView: View {
    @EnvironmentObject var model: AppModel
    let thermostat: LocalThermostat
    let canControl: Bool
    @State<FanRunDuration> private var duration = .fifteen

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Fan control", systemImage: "fanblades").font(.headline)
            HStack(spacing: 12) {
                Picker("Run for", selection: $duration) {
                    ForEach(FanRunDuration.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }.frame(maxWidth: 260)
                Button("Run fan") {
                    Task { await model.setFan(on: true, duration: duration, thermostat: thermostat) }
                }.buttonStyle(.borderedProminent)
                    .disabled(model.fanFeedback?.isPending == true && model.fanFeedback?.action == .start)
                Spacer()
                Button("Stop / Auto") {
                    Task { await model.setFan(on: false, thermostat: thermostat) }
                }.disabled(model.fanFeedback?.isPending == true && model.fanFeedback?.action == .stop)
            }.disabled(!canControl)
            if let feedback = model.fanFeedback, feedback.thermostatID == thermostat.id {
                HStack(spacing: 8) {
                    if feedback.isPending {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Waiting for fan status")
                    } else {
                        Image(systemName: feedback.phase == .confirmed ? "checkmark.circle" : "info.circle")
                    }
                    Text(feedback.message)
                }
                .font(.callout)
                .foregroundStyle(feedback.phase == .confirmed ? mint : Color.secondary)
            }
            if let run = model.fanRun, run.thermostatID == thermostat.id {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 5) {
                        if run.returnAttempted {
                            Text(model.busy ? "Returning fan to Auto…" : "Return to Auto could not be confirmed. Use Stop / Auto to try again.")
                                .foregroundStyle(.orange)
                        } else if context.date >= run.endsAt {
                            Text("Timer ended — waiting for a connection and available controls.")
                                .foregroundStyle(.orange)
                        } else {
                            HStack(spacing: 4) {
                                Text("Return to Auto in")
                                Text(run.endsAt, style: .timer).monospacedDigit().fixedSize()
                                Text("· \(run.endsAt.formatted(date: .omitted, time: .shortened))")
                            }.foregroundStyle(mint)
                        }
                        if !run.startConfirmed {
                            Text("Fan On could not be confirmed. The return-to-Auto timer is still saved.")
                                .foregroundStyle(.orange)
                        }
                    }.font(.callout)
                }
            }
            Text("Stop / Auto ends a manual fan run. Heating, cooling, or the thermostat’s minimum hourly runtime may still run the fan.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Timed runs need this app open and your Mac awake on the home network. If interrupted, returning to Auto waits until the app reconnects.")
                .font(.caption).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SystemStatusView: View {
    let status: SystemIndicator
    var body: some View {
        VStack(spacing: 5) {
            Text("SYSTEM")
                .font(.system(size: 10, weight: .semibold)).tracking(2)
                .foregroundStyle(.secondary)
            Group {
                switch status {
                case .cooling(let active):
                    Image(systemName: "snowflake").foregroundStyle(active ? Color.blue : .gray)
                case .heating(let active):
                    Image(systemName: "flame.fill").foregroundStyle(active ? Color.red : .gray)
                case .off:
                    Text("OFF").font(.system(size: 30, weight: .medium, design: .rounded)).foregroundStyle(.gray)
                case .automaticIdle:
                    HStack(spacing: 8) {
                        Image(systemName: "flame.fill")
                        Image(systemName: "snowflake")
                    }.font(.system(size: 30, weight: .light)).foregroundStyle(.gray)
                case .unknown:
                    Text("—").foregroundStyle(.gray)
                }
            }.font(.system(size: 50, weight: .light)).frame(height: 98)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.description)
        .help(status.description)
    }
}

private struct FanStatusView: View {
    let running: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var spinning: Bool { running == true && !reduceMotion }
    private var title: String {
        switch running {
        case true: return "FAN RUNNING"
        case false: return "FAN OFF"
        default: return "FAN UNKNOWN"
        }
    }
    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold)).tracking(2)
                .foregroundStyle(.secondary)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !spinning)) { context in
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 50, weight: .light))
                    .foregroundStyle(running == true ? mint : Color.secondary)
                    .rotationEffect(.degrees(spinning ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) * 180 : 0))
                    .frame(height: 98)
            }.accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .help(running == nil ? "Current fan status is unavailable. Reconnect or refresh to check." : "Current fan operation reported by the thermostat.")
    }
}

private extension View {
    func card() -> some View {
        self.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.055)))
    }
}
