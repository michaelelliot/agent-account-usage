import AppKit
import SwiftUI

@main
struct SubSmasherApp: App {
    @State private var model = UsageModel()

    init() {
        // No Dock icon. Info.plist sets LSUIElement too; this covers unbundled `swift run`.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            UsageMenuView(model: model)
        } label: {
            Image(nsImage: model.menuBarImage)
            if let text = model.menuBarText {
                Text(text)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
