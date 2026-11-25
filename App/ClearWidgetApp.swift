import SwiftUI
import UIKit

@main
struct ClearWidgetApp: App {
    @State private var status = ""
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("Widget") {
                        Text("Agregá ClearWidget mediano a la pantalla de inicio y elegí la apariencia Transparente en la personalización de iOS.")
                        Text("Versión de validación. Todavía no hay datos meteorológicos reales.")
                    }
                    Section("Prueba de enlaces") {
                        Button("Abrir Clima de Apple") { launch("weather://") }
                        Button("Abrir Calendario de Apple") { launch("calshow://") }
                        if !status.isEmpty { Text(status).font(.footnote) }
                    }
                }.navigationTitle("ClearWidget")
            }.onOpenURL { url in
                guard url.scheme == "clearwidget" else { return }
                switch url.host {
                case "weather": launch("weather://")
                case "calendar": launch("calshow://")
                default: break
                }
            }
        }
    }
    private func launch(_ address: String) {
        guard let url = URL(string: address) else { return }
        UIApplication.shared.open(url, options: [:]) { accepted in
            status = accepted ? "iOS aceptó la apertura." : "iOS rechazó la apertura."
        }
    }
}
