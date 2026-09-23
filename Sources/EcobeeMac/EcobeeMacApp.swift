import SwiftUI
import LocalCore

@main struct EcobeeMacApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Ecobee Local", id: "main") {
            ContentView().environmentObject(model)
                .frame(minWidth: 880, minHeight: 650)
                .task { await model.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.helper.stop() }
        }
        .defaultSize(width: 1020, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Thermostat") { Task { await model.refresh() } }
                    .keyboardShortcut("r").disabled(model.busy || model.snapshot == nil)
            }
        }
        MenuBarExtra {
            MenuPanel().environmentObject(model)
        } label: {
            Label(model.snapshot?.thermostats.first.map { (model.demo ? "Demo " : "") + model.unit.text($0.current) } ?? "Ecobee", systemImage: "thermometer.medium")
        }
    }
}

struct MenuPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if let thermostat = model.snapshot?.thermostats.first {
            Text("\(model.demo ? "Demo · " : "")\(model.snapshot?.name ?? "Ecobee")")
            Text("\(model.unit.text(thermostat.current)) · \(thermostat.modeName)")
            if !model.demo && !model.connected { Text("Disconnected · last known reading") }
        } else { Text("Ecobee Local") }
        Divider()
        Button("Open Thermostat") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Refresh") { Task { await model.refresh() } }.disabled(model.busy || model.snapshot == nil)
        Divider()
        Button("Quit Ecobee Local") { model.helper.stop(); NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
