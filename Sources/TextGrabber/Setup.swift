import AppKit
import SwiftUI
import ServiceManagement
import Combine

/// First-run setup: the two permissions, the shortcut, open at login. Shown until the user finishes it,
/// and from the menu any time after.
final class SetupState: ObservableObject {
    @Published var screenRecording = CGPreflightScreenCaptureAccess()
    @Published var accessibility = AccessibilityText.isTrusted
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    /// Screen Recording was requested in this run: macOS applies it only after a restart.
    @Published var screenRecordingRequested = false

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AccessibilityText.isTrusted
    }
}

struct SetupView: View {
    @ObservedObject var state: SetupState
    var tryCapture: () -> Void
    var finish: () -> Void
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var shortcut: String {
        Shortcut.stored(for: .captureText)?.display ?? "no shortcut set"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up TextGrabber").font(.title2.weight(.semibold))
                    Text("Two permissions, then you're ready. Everything stays on this Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            step(done: state.screenRecording,
                 title: "Screen Recording",
                 detail: state.screenRecording
                    ? "Allowed. TextGrabber can read the area you select."
                    : state.screenRecordingRequested
                        ? "Turn on TextGrabber in the list that opened, then restart TextGrabber: macOS applies this permission only after a restart."
                        : "Needed to read the area you select. Nothing is recorded or kept.",
                 required: true) {
                if state.screenRecording {
                    EmptyView()
                } else if state.screenRecordingRequested {
                    Button("Restart TextGrabber") { Self.relaunch() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Allow…") {
                        CGRequestScreenCaptureAccess()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                        state.screenRecordingRequested = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            step(done: state.accessibility,
                 title: "Accessibility (recommended)",
                 detail: state.accessibility
                    ? "Allowed. Emoji and symbols such as ⌘ come out exactly when the app exposes its text."
                    : "Lets TextGrabber use an app's own text where it matches what it read, so emoji and symbols such as ⌘ come out exactly. Optional.",
                 required: false) {
                if !state.accessibility {
                    Button("Allow…") { AccessibilityText.requestAccess() }
                }
            }

            step(done: false, title: "Try it",
                 detail: "Press \(shortcut) anywhere, or click the menu bar icon, then drag over some text. It is copied to the clipboard. Shortcuts can be changed in Settings.",
                 required: false, showsStatus: false) {
                Button("Try Now") { tryCapture() }.disabled(!state.screenRecording)
            }

            Toggle("Open TextGrabber when I log in", isOn: $state.openAtLogin)
                .onChange(of: state.openAtLogin) { _, enabled in
                    if enabled { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                }

            HStack {
                if !state.screenRecording {
                    Text("TextGrabber cannot capture until Screen Recording is allowed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(state.screenRecording ? "Done" : "Finish Later") { finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onReceive(timer) { _ in state.refresh() }
    }

    @ViewBuilder
    private func step<Action: View>(done: Bool, title: String, detail: String, required: Bool, showsStatus: Bool = true,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: !showsStatus ? "keyboard" : done ? "checkmark.circle.fill" : required ? "exclamationmark.circle" : "circle")
                .font(.title2)
                .foregroundStyle(!showsStatus ? Color.accentColor : done ? .green : required ? .orange : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
        }
    }

    /// Starts a new copy of the app, then quits this one.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
