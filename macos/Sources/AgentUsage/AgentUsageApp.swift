import AppKit
import SwiftUI

@main
struct AgentUsageApp: App {
    @State private var model = UsageModel()

    init() {
        // No Dock icon. Info.plist sets LSUIElement too; this covers unbundled `swift run`.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            UsageMenuView(model: model)
        } label: {
            Image(systemName: model.symbolName)
            if let text = model.menuBarText {
                Text(text)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
