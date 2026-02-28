import AppKit
import Foundation

enum MacOpenPanel {
    static func pickFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.prompt = "Select"

        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }
}
