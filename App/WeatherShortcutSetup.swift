import SwiftUI
import UIKit

struct WeatherShortcutSetup: View {
    @State private var status: String?
    @State private var copied = false
    private func prepare() {
        copied = false
        do {
            guard let bundleID = Bundle.main.bundleIdentifier else { throw CocoaError(.fileReadCorruptFile) }
            let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
                .flatMap { try? Data(contentsOf: $0) }
            let team = profile.flatMap { WeatherShortcutRecipe.teamIdentifier(profile: $0) }
            let data = try WeatherShortcutRecipe.encoded(bundleID: bundleID, teamID: team)
            UIPasteboard.general.setItems([[WeatherShortcutRecipe.pasteboardType: data]], options: [.localOnly: true])
            guard UIPasteboard.general.data(forPasteboardType: WeatherShortcutRecipe.pasteboardType) == data else {
                throw CocoaError(.fileWriteUnknown)
            }
            copied = true
            status = "14 acciones copiadas. En Atajos, creá uno vacío, mantené pulsado el área de acciones y tocá Pegar. Luego ejecutalo."
        } catch {
            status = "No se pudieron preparar las acciones: " + error.localizedDescription
        }
    }
    var body: some View {
        Button("Preparar atajo de clima de Apple") { prepare() }
        if let status { Text(status).font(.footnote) }
        if copied {
            Link("Abrir Atajos", destination: URL(string: "shortcuts://")!)
        }
    }
}
