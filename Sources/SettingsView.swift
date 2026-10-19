import AppKit
import ServiceManagement
import SwiftUI

/// Settings window: fade-out, global hotkeys (with permission guidance), menu bar item, launch at login, support.
struct SettingsView: View {
    @EnvironmentObject private var model: BoardModel
    @AppStorage("showMenuBar") private var showMenuBar = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var explainPermission = false
    @State private var trusted = AXIsProcessTrusted()
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Playback") {
                Slider(value: $model.fadeOut, in: 0...5, step: 0.1) {
                    Text("Fade out")
                } minimumValueLabel: { Text("0s") } maximumValueLabel: { Text("5s") }
                Text("Stopping a pad fades it out over \(model.fadeOut, specifier: "%.1f") seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Keyboard") {
                Toggle("Global triggers (⌃⌥ + pad key) from any app", isOn: Binding(
                    get: { model.globalKeys },
                    set: { on in
                        if on && !AXIsProcessTrusted() { explainPermission = true } else { model.globalKeys = on }
                    }))
                if model.globalKeys && !trusted {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PadSounds needs Accessibility access to hear keys while other apps are in front. Enable it in System Settings → Privacy & Security → Accessibility, then return here.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
                    }
                }
            }

            Section("General") {
                Toggle("Show menu bar item", isOn: $showMenuBar)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { setLaunchAtLogin(launchAtLogin) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Button("Support / Donate ❤️") { Support.open() }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
            } footer: {
                Text("PadSounds is free and open source. Your support keeps it going.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
        }
        .alert("Allow global triggers?", isPresented: $explainPermission) {
            Button("Continue") {
                model.requestAccessibility()
                model.globalKeys = true
                trusted = AXIsProcessTrusted()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To trigger pads with ⌃⌥ + key while another app is focused, macOS requires you to grant PadSounds Accessibility access. PadSounds only looks for its own pad keys and never records or sends your typing anywhere.")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't update launch at login: \(error.localizedDescription)"
        }
    }
}
