import SwiftUI
import WidgetKit
import CoreLocation
import AppIntents

@main
struct ClearWidgetApp: App {
    @State private var installedWidgets = "Sin consultar"
    @State private var shortcutsStatus = "Sin consultar"
    @State private var locationManager = CLLocationManager()
    init() {
        ClearWidgetShortcuts.updateAppShortcutParameters()
        ClearSignSetup.purgeAbandonedSetup()
        ClearSign.shared.register()
    }
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("ClearWidget") {
                        Text("En la galería, elegí el tamaño pequeño o mediano. En Editar widget, el pequeño permite elegir Glass Small 7, Clear Small 20 o Clear Small 21. El mediano conserva Clear Medium.")
                        Text("Acción principal configura el panel de inicio del mediano o todo el pequeño. Clear Small 21 ofrece Calendario, Clima y Actividad por separado. Sin asignar no se abre ninguna app.")
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
                        Text("Ubicación automática · temperaturas en °C. Habilitá la ubicación de la app y sus widgets para que el respaldo funcione al viajar.")
                        Button("Permitir ubicación") { locationManager.requestWhenInUseAuthorization() }
                        Text("Apple Weather mediante Atajos (integración experimental). Configurá Guardar clima de Apple con el pronóstico JSON y ejecutá tu atajo manualmente o mediante una automatización cada hora.")
                        Text("Para actualizar al tocar el widget, asigná ese atajo a Acción principal o Abrir Clima. Podés añadir Abrir app al final del atajo si lo deseás.")
                        Link("Respaldo: Open-Meteo · ECMWF", destination: URL(string: "https://open-meteo.com/")!)
                        Link("Modelo ECMWF", destination: URL(string: "https://www.ecmwf.int/")!)
                    }
                    Section("Actividad y diagnóstico") {
                        Text("En Salud, habilitá la escritura de Mi Fitness. El widget recibe totales de una sola fuente mediante Guardar actividad ClearWidget. Elegí la fuente en Editar widget.")
                        Text("Ejecutá Diagnóstico ClearWidget en Atajos para consultar los datos de la extensión.")
                        Button("Registrar acciones de Atajos") {
                            ClearWidgetShortcuts.updateAppShortcutParameters()
                            shortcutsStatus = "Registro solicitado a iOS; no confirma que Atajos las muestre."
                        }
                        Button("Probar comunicación con widgets") {
                            do { try ShortcutBridge.beginProbe(); shortcutsStatus = "Prueba enviada. Consultá el resultado cuando iOS actualice el widget." }
                            catch { shortcutsStatus = error.localizedDescription }
                            WidgetCenter.shared.reloadTimelines(ofKind: "ClearWidget")
                        }
                        Button("Consultar diagnóstico") {
                            do { shortcutsStatus = try ShortcutBridge.diagnostic() }
                            catch { shortcutsStatus = error.localizedDescription }
                        }
                        Text(shortcutsStatus).font(.footnote)
                    }
                    Section("Firma") { SigningPanel(); ClearSignSetupPanel(); ClearRecoveryExportPanel() }
                    Section("Diseño") {
                        Text("Referencias Clear Medium, Glass Small 7 y Clear Small de Lokki. Uso personal. No distribuir los recursos originales sin autorización.")
                    }
                }.navigationTitle("ClearWidget")
                    .onAppear { ClearSign.shared.update(); ClearSign.shared.schedule() }
            }
        }
    }
}
