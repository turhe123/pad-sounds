import AppKit
import SwiftUI

/// Opens the donation page; shared by the toolbar, menu bar item and Settings.
enum Support {
    static func open() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
    }
}

/// App entry point: the main pad window, an optional menu bar item, and the Settings window.
@main
struct PadSoundsApp: App {
    @StateObject private var model = BoardModel()
    @AppStorage("showMenuBar") private var showMenuBar = false

    var body: some Scene {
        Window("PadSounds", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 720, height: 680)
        .commands {
            CommandGroup(after: .help) {
                Button("Support / Donate ❤️") { Support.open() }
            }
        }

        MenuBarExtra("PadSounds", systemImage: "square.grid.3x3.fill", isInserted: $showMenuBar) {
            MenuBarContent()
                .environmentObject(model)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

/// Items shown in the optional menu bar extra.
private struct MenuBarContent: View {
    @EnvironmentObject private var model: BoardModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show PadSounds") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Stop All") { model.stopAll() }
        Divider()
        Button("Support / Donate ❤️") { Support.open() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit PadSounds") { NSApp.terminate(nil) }
    }
}
