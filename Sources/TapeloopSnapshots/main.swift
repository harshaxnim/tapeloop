#if os(macOS)
    import AppKit
    import SwiftUI
    import TapeloopUI

    /// Renders Tapeloop's UI to PNG files, in light and dark, from sample data: for CI artifacts, documentation and
    /// visual review. Usage: TapeloopSnapshots <output-folder> [name-filter]
    @MainActor
    enum Snapshots {
        static var folder = URL(fileURLWithPath: "build/snapshots")
        static var filter: String?
        static var count = 0

        static func render<V: View>(_ name: String, width: CGFloat? = nil, @ViewBuilder _ view: () -> V) throws {
            guard filter.map({ name.contains($0) }) ?? true else { return }
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                let content = view()
                    .frame(width: width)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                var image: CGImage?
                NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                    image = renderer.cgImage
                }
                guard let image else { throw SnapshotError.renderFailed(name) }
                try write(image, to: folder.appendingPathComponent("\(name)-\(suffix).png"))
                count += 1
            }
        }

        static func renderAll() throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            PopoverView.animates = false
            for (name, state, selection, quick) in Samples.popoverStates() {
                try render("popover-\(name)") {
                    let model = PopoverModel(state: state, selection: selection)
                    model.quickMinutes = quick
                    if name == "meeting" { model.quickMinutes = nil }
                    Samples.selectSample(name, in: model)
                    return PopoverView(model: model)
                }
            }
            try render("menubar-icons") { MenuBarStrip() }
            for tab in SettingsModel.Tab.allCases {
                try render("settings-\(tab.rawValue.lowercased())") {
                    let model = SettingsModel(settings: Samples.settings, services: Samples.services()) { _ in }
                    model.tab = tab
                    return SettingsView(model: model, scrolls: false)
                }
            }
            for (name, model) in [
                ("library", LibraryModel.sample(query: "")), ("library-search", LibraryModel.sample()),
                ("library-transcribing", LibraryModel.sample(query: "", transcribing: true)),
                ("library-empty", LibraryModel(recordings: [])),
            ] {
                try hosted(name, size: LibraryView.idealSize) { LibraryView(model: model) }
            }
            for (name, status) in [("installed", SpeechModelStatus.installed), ("not-installed", .notInstalled)] {
                try render("settings-transcripts-\(name)") {
                    var services = Samples.services()
                    services.speechModelStatus = { status }
                    var settings = Samples.settings
                    settings.transcription.mode = name == "installed" ? .live : .afterSave
                    let model = SettingsModel(settings: settings, services: services) { _ in }
                    model.tab = .transcripts
                    return SettingsView(model: model, scrolls: false)
                }
            }
            for step in 1...5 {
                try render("onboarding-\(step)") {
                    let model = OnboardingModel(services: Samples.services())
                    model.step = step
                    return OnboardingView(model: model)
                }
            }
        }

        /// Renders through an off-screen hosting view (scroll views and text fields draw, unlike ImageRenderer).
        static func hosted<V: View>(_ name: String, size: CGSize, @ViewBuilder _ view: () -> V) throws {
            guard filter.map({ name.contains($0) }) ?? true else { return }
            for dark in [false, true] {
                guard let rep = HostedSnapshot.image(of: view(), size: size, dark: dark),
                    let data = rep.representation(using: .png, properties: [:])
                else { throw SnapshotError.renderFailed(name) }
                try data.write(to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                count += 1
            }
        }

        static func write(_ image: CGImage, to url: URL) throws {
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw SnapshotError.renderFailed(url.lastPathComponent)
            }
            try data.write(to: url)
        }
    }

    /// The three icon states at real size and magnified.
    struct MenuBarStrip: View {
        var body: some View {
            HStack(spacing: 18) {
                ForEach(RecorderStatus.allCases, id: \.self) { status in
                    VStack(spacing: 6) {
                        HStack(spacing: 10) {
                            Image(nsImage: CassetteIcon.image(for: status))
                            Image(nsImage: CassetteIcon.image(for: status, width: 81))
                        }
                        Text(status.label).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
    }

    enum SnapshotError: Error {
        case renderFailed(String)
    }

    let arguments = CommandLine.arguments.dropFirst()
    Snapshots.folder = URL(fileURLWithPath: arguments.first ?? "build/snapshots")
    Snapshots.filter = arguments.dropFirst().first
    try MainActor.assumeIsolated { try Snapshots.renderAll() }
    print("Rendered \(MainActor.assumeIsolated { Snapshots.count }) snapshots to \(Snapshots.folder.path)")
#else
    print("Snapshots render on macOS only.")
#endif
