import SwiftUI
import WidgetKit

@main
struct ClearWidgetApp: App {
    @State private var installedWidgets = "Sin consultar"
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("ClearWidget") {
                        Text("En la galería, elegí el tamaño pequeño (Glass Small 7) o mediano (Clear Medium) de ClearWidget. Mantené pulsado el widget y elegí Editar widget.")
                        Text("Acción principal configura el panel de inicio del mediano o todo el pequeño. Abrir Clima y Abrir Calendario solo se utilizan en el mediano. Sin asignar no se abre ninguna app.")
                        Text("Elegí la apariencia Transparente de iOS para el cristal nativo.")
                    }
                    Section("Diagnóstico de widgets") {
                        Text("Versión " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"))
                        Text(installedWidgets)
                        Button("Consultar widgets añadidos") {
                            WidgetCenter.shared.getCurrentConfigurations { result in
                                let message: String
                                switch result {
                                case .success(let widgets):
                                    let items = widgets.map { info in
                                        let size: String
                                        switch info.family {
                                        case .systemSmall: size = "Pequeño"
                                        case .systemMedium: size = "Mediano"
                                        default: size = String(describing: info.family)
                                        }
                                        return "\(size) · \(info.kind)"
                                    }
                                    message = items.isEmpty ? "Ningún widget añadido" : items.joined(separator: "\n")
                                case .failure(let error):
                                    message = error.localizedDescription
                                }
                                DispatchQueue.main.async { installedWidgets = message }
                            }
                        }
                        Button("Actualizar widgets") { WidgetCenter.shared.reloadAllTimelines() }
                    }
                    Section("Pronóstico") {
                        Text("Córdoba Capital · sin GPS · temperaturas en °C")
                        Link("Datos: Open-Meteo · ECMWF IFS 9 km", destination: URL(string: "https://open-meteo.com/")!)
                        Link("Modelo ECMWF", destination: URL(string: "https://www.ecmwf.int/")!)
                    }
                    Section("Diseño") {
                        Text("Referencias Clear Medium y Glass Small 7 de Lokki. Uso personal. No distribuir los recursos originales sin autorización.")
                    }
                }.navigationTitle("ClearWidget")
            }
        }
    }
}
