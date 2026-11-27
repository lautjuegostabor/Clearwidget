import SwiftUI
import UIKit

struct WeatherShortcutSetup: View {
    @State private var status: String?
    @State private var copied = false
    @State private var clipboardDiagnostic: String?
    @Environment(\.openURL) private var openURL

    private func prepare() {
        copied = false
        do {
            guard let bundleID = Bundle.main.bundleIdentifier else { throw CocoaError(.fileReadCorruptFile) }
            let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
                .flatMap { try? Data(contentsOf: $0) }
            let team = profile.flatMap { WeatherShortcutRecipe.teamIdentifier(profile: $0) }
            let values = try WeatherShortcutRecipe.encodedItems(bundleID: bundleID, teamID: team)
            let type = WeatherShortcutRecipe.pasteboardType
            let board = UIPasteboard.general
            let items: [[String: Any]] = values.map { [type: $0] }
            board.setItems(items, options: [.localOnly: true])
            let stored = board.items
            guard stored.count == values.count,
                  zip(stored, values).allSatisfy({ pair in (pair.0[type] as? Data) == pair.1 })
            else { throw CocoaError(.fileWriteUnknown) }
            copied = true
            status = "\(values.count) acciones binarias copiadas por separado. En Atajos, pegá desde el menú de una acción Comentar."
            openURL(URL(string: "shortcuts://create-shortcut")!)
        } catch {
            status = "No se pudieron preparar las acciones: " + error.localizedDescription
        }
    }

    private func inspectClipboard() {
        let type = WeatherShortcutRecipe.pasteboardType
        let board = UIPasteboard.general
        let values = board.items.compactMap { $0[type] as? Data }
        clipboardDiagnostic = WeatherShortcutRecipe.inspect(values)
    }

    var body: some View {
        Button("Preparar atajo de clima de Apple") { prepare() }
        if let status { Text(status).font(.footnote) }
        if copied {
            Link("Abrir editor de Atajos", destination: URL(string: "shortcuts://create-shortcut")!)
        }
        DisclosureGroup("Diagnóstico de portapapeles") {
            Text("Si el pegado no funciona, este diagnóstico puede identificar el formato de una acción copiada desde Atajos. No lee texto ni envía datos.")
                .font(.caption)
            Button("Inspeccionar acciones copiadas") { inspectClipboard() }
            if let clipboardDiagnostic { Text(clipboardDiagnostic).font(.caption).textSelection(.enabled) }
        }
    }
}
