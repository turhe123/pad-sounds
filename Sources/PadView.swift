import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One rounded-square pad: label, key badge, progress ring, drop target, and the inspector popover.
struct PadView: View {
    @EnvironmentObject private var model: BoardModel
    @Binding var pad: Pad
    @State private var pressed = false
    @State private var showInspector = false
    @State private var showImporter = false
    @State private var dropTargeted = false

    private var isPlaying: Bool { model.playing.contains(pad.id) }
    private var isEmpty: Bool { pad.fileName == nil }

    var body: some View {
        ZStack {
            face
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        model.press(pad)
                    }
                    .onEnded { _ in
                        pressed = false
                        model.release(pad)
                    })
                .overlay(RightClickCatcher { showInspector = true })

            VStack {
                HStack {
                    Button { showInspector = true } label: {
                        Image(systemName: "gearshape.fill").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.85))
                    .help("Edit pad")
                    Spacer()
                }
                Spacer()
            }
            .padding(8)
        }
        .aspectRatio(1, contentMode: .fit)
        .popover(isPresented: $showInspector, arrowEdge: .bottom) {
            PadInspector(pad: $pad) {
                showInspector = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showImporter = true }
            }
            .environmentObject(model)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { model.assignFile(url, to: pad.id) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.assignFile(url, to: pad.id)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var face: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return ZStack {
            shape.fill(isEmpty ? AnyShapeStyle(Color.secondary.opacity(0.12))
                               : AnyShapeStyle(pad.color.color.gradient))
            shape.strokeBorder(dropTargeted ? Color.accentColor : Color.white.opacity(isPlaying ? 0.9 : 0.15),
                               lineWidth: dropTargeted || isPlaying ? 3 : 1)

            if isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "plus").font(.title)
                    Text("Drop audio here").font(.caption)
                }
                .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.25), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: isPlaying ? model.progress[pad.id] ?? 0 : 0)
                            .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : modeIcon)
                            .foregroundStyle(.white)
                    }
                    .frame(width: 34, height: 34)
                    Text(pad.label)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                }
            }

            if let key = pad.key {
                Text(key.uppercased())
                    .font(.system(.caption, design: .monospaced).bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(isEmpty ? Color.secondary : Color.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(8)
            }

            if model.broken.contains(pad.id) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.white, .red)
                    .font(.title3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
                    .help("The audio file is missing or unreadable")
            }
        }
        .scaleEffect(pressed ? 0.96 : 1)
        .animation(.easeOut(duration: 0.08), value: pressed)
        .contentShape(shape)
    }

    private var modeIcon: String {
        switch pad.mode {
        case .once: return "play.fill"
        case .hold: return "hand.point.down.fill"
        case .toggle: return "repeat"
        }
    }
}

/// Popover editor for a pad's label, colour, key, volume, loop, mode and file.
struct PadInspector: View {
    @EnvironmentObject private var model: BoardModel
    @Binding var pad: Pad
    let replaceFile: () -> Void

    var body: some View {
        Form {
            TextField("Label", text: $pad.label)
            Picker("Color", selection: $pad.color) {
                ForEach(PadColor.allCases) { c in
                    Label(c.rawValue.capitalized, systemImage: "circle.fill").foregroundStyle(c.color).tag(c)
                }
            }
            TextField("Key", text: Binding(
                get: { pad.key?.uppercased() ?? "" },
                set: { model.setKey($0, for: pad.id) }))
                .help("A single key that triggers this pad")
            Slider(value: $pad.volume, in: 0...1) { Text("Volume") }
                .onChange(of: pad.volume) { model.volumeChanged(pad) }
            Toggle("Loop", isOn: $pad.loops)
            Picker("Mode", selection: $pad.mode) {
                ForEach(PlayMode.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Button(pad.fileName == nil ? "Choose File…" : "Replace File…", action: replaceFile)
                Spacer()
                Button("Clear Pad", role: .destructive) { model.clearPad(pad.id) }
                    .disabled(pad.fileName == nil)
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .padding(.vertical, 4)
    }
}

/// Transparent AppKit overlay that only intercepts right-clicks, so left-clicks still reach the pad.
private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    final class CatcherView: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .rightMouseDown ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with event: NSEvent) { action?() }
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }
}
