import SwiftUI

@main
struct EOFApp: App {
    @StateObject private var model = AppModel.shared
    @StateObject private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    /// The scene is identified by the document a new window should open with; the first window and
    /// windows from "New Window" have none.
    static let windowID = "editor"

    var body: some Scene {
        WindowGroup(id: EOFApp.windowID, for: UUID.self) { $documentID in
            RootView(initialDocument: documentID)
                .environmentObject(model)
                .environmentObject(settings)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.checkExternalChanges()
            case .inactive, .background: model.saveAll()
            @unknown default: break
            }
        }
        .commands {
            EditorCommands(model: model, settings: settings)
        }
    }
}

/// The menu bar and keyboard shortcuts. Commands go to the window that has focus.
struct EditorCommands: Commands {
    let model: AppModel
    @ObservedObject var settings: AppSettings
    @FocusedObject private var window: WindowState?
    @Environment(\.openWindow) private var openWindow

    private func send(_ command: EditorCommand) {
        window?.commands.send(command)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New File") { model.newDocument() }
                .keyboardShortcut("n")
            if UIApplication.shared.supportsMultipleScenes {
                Button("New Window") { openWindow(id: EOFApp.windowID) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            Button("Open…") { send(.openFile) }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { send(.save) }
                .keyboardShortcut("s")
            Button("Save As…") { send(.saveAs) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Close Document") { send(.closeDocument) }
                .keyboardShortcut("w")
        }
        CommandMenu("Find") {
            Button("Find…") { send(.find) }
                .keyboardShortcut("f")
            Button("Find and Replace…") { send(.replace) }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Divider()
            Button("Go to Line…") { send(.goToLine) }
                .keyboardShortcut("l")
            Button("Outline") { send(.outline) }
                .keyboardShortcut("o", modifiers: [.command, .option])
        }
        CommandMenu("Editor") {
            Button("Toggle Preview") { send(.togglePreview) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button(window?.isSplit == true ? "Close Split" : "Split Editor") { send(.toggleSplit) }
                .keyboardShortcut("\\")
            Divider()
            Button("Bigger Text") { settings.adjustFontSize(by: 1) }
                .keyboardShortcut("+")
            Button("Smaller Text") { settings.adjustFontSize(by: -1) }
                .keyboardShortcut("-")
            Divider()
            Toggle("Wrap Lines", isOn: $settings.wrapLines)
            Toggle("Line Numbers", isOn: $settings.showLineNumbers)
            Toggle("Show Invisibles", isOn: $settings.showInvisibles)
        }
    }
}
