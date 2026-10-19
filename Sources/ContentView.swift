import SwiftUI

/// Main window: the 4×4 pad grid, the toolbar (Stop All, master volume, output, Keys Active) and toasts.
struct ContentView: View {
    @EnvironmentObject private var model: BoardModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach($model.pads) { $pad in
                PadView(pad: $pad)
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 560)
        .overlay(alignment: .bottom) { toastView }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .toolbar { toolbar }
        .navigationTitle("PadSounds")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.stopAll() } label: { Label("Stop All", systemImage: "stop.fill") }
                .help("Stop all pads (Esc)")

            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                Slider(value: $model.masterVolume, in: 0...1).frame(width: 110)
            }
            .help("Master volume")

            Picker("Output", selection: $model.outputUID) {
                Text("System Default").tag("")
                ForEach(model.devices) { Text($0.name).tag($0.uid) }
            }
            .frame(maxWidth: 180)
            .help("Output device for the whole board")

            Toggle(isOn: $model.keysActive) { Label("Keys Active", systemImage: "keyboard") }
                .toggleStyle(.button)
                .help("Trigger pads with their assigned keys while this window is focused")

            Button { Support.open() } label: { Label("Support / Donate ❤️", systemImage: "heart.fill") }
                .labelStyle(.titleAndIcon)
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let message = model.toast {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
