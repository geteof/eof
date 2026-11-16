import SwiftUI

@main
struct TesseraApp: App {
    @StateObject private var model = AppModel.shared
    @StateObject private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(settings)
                .onOpenURL { model.openAny($0) }
                .onAppear {
                    #if DEBUG
                    if DebugLaunch.isActive {
                        DebugLaunch.open(in: model)
                        return
                    }
                    #endif
                    model.restoreSession()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.checkExternalChanges()
            case .inactive, .background: model.saveAll()
            @unknown default: break
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New File") { model.newDocument() }
                    .keyboardShortcut("n")
                Button("Open…") { model.commands.send(.openFile) }
                    .keyboardShortcut("o")
                Button("Open Folder…") { model.commands.send(.openFolder) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.commands.send(.save) }
                    .keyboardShortcut("s")
                Button("Save As…") { model.commands.send(.saveAs) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Close Document") { model.commands.send(.closeDocument) }
                    .keyboardShortcut("w")
            }
            CommandMenu("Find") {
                Button("Find…") { model.commands.send(.find) }
                    .keyboardShortcut("f")
                Button("Find and Replace…") { model.commands.send(.replace) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Find in Folder…") { model.commands.send(.findInFolder) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Go to Line…") { model.commands.send(.goToLine) }
                    .keyboardShortcut("l")
                Button("Outline") { model.commands.send(.outline) }
                    .keyboardShortcut("o", modifiers: [.command, .option])
            }
            CommandMenu("Editor") {
                Button("Toggle Preview") { model.commands.send(.togglePreview) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
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
}
