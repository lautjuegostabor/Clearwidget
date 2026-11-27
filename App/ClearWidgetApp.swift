import SwiftUI
import WidgetKit
import CoreLocation
import AppIntents
import UIKit

@main
struct ClearWidgetApp: App {
    @State private var installedWidgets = "Sin consultar"
    @State private var shortcutsStatus = "Sin consultar"
    @State private var locationManager = CLLocationManager()
    @State private var widgetRefreshStatus = ""
    @State private var locationStatus = ""
    @Environment(\.scenePhase) private var scenePhase
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
                        Text("Versión " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") + " · Build " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))
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
                        Button("Actualizar widgets") {
                            WidgetCenter.shared.reloadAllTimelines()
                            widgetRefreshStatus = "Recarga solicitada a iOS. La actualización visual puede demorarse."
                        }
                        if !widgetRefreshStatus.isEmpty { Text(widgetRefreshStatus).font(.caption) }
                    }
                    Section("Pronóstico") {
                        Text("Ubicación automática · temperaturas en °C. Habilitá la ubicación de la app y sus widgets para que el respaldo funcione al viajar.")
                        Button("Permitir ubicación") {
                            switch locationManager.authorizationStatus {
                            case .notDetermined:
                                locationManager.requestWhenInUseAuthorization()
                                locationStatus = "Solicitud enviada. Elegí el permiso en iOS."
                            case .denied:
                                locationStatus = "Permiso denegado. Habilitá la ubicación en Ajustes."
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url) { success in
                                        if !success { DispatchQueue.main.async { locationStatus = "No se pudieron abrir Ajustes." } }
                                    }
                                }
                            case .restricted: locationStatus = "El sistema restringe el acceso a ubicación."
                            case .authorizedAlways, .authorizedWhenInUse: locationStatus = "Ubicación autorizada."
                            @unknown default: locationStatus = "Estado de ubicación desconocido."
                            }
                        }
                        if !locationStatus.isEmpty { Text(locationStatus).font(.caption) }
                        Text("Usá el atajo ClearWidget - Apple Weather (texto). La app convierte y valida los datos de Apple. No uses el mecanismo anterior de copiado de acciones.")
                        Text("Para actualizar al tocar el widget, asigná ese atajo a Acción principal o Abrir Clima. Podés añadir Abrir app al final del atajo si lo deseás.")
                        Link("Respaldo: Open-Meteo · ECMWF", destination: URL(string: "https://open-meteo.com/")!)
                        Link("Modelo ECMWF", destination: URL(string: "https://www.ecmwf.int/")!)
                    }
                    Section("Actividad y diagnóstico") {
                        Text("En Salud, habilitá la escritura de Mi Fitness. El widget recibe totales de una sola fuente mediante Guardar actividad ClearWidget. Elegí la fuente en Editar widget.")
                        Text("Ejecutá Diagnóstico ClearWidget en Atajos para comprobar la ejecución directa en la extensión y la recepción del timeline.")
                        Button("Registrar acciones de Atajos") {
                            ClearWidgetShortcuts.updateAppShortcutParameters()
                            shortcutsStatus = "Registro solicitado a iOS; no confirma que Atajos las muestre."
                        }
                        Link("Abrir Atajos para ejecutar el diagnóstico", destination: URL(string: "shortcuts://")!)
                        Text("Las acciones escriben directamente en WidgetKit. No necesitan el puente Keychain compartido. El diagnóstico anterior de la app no verifica esta ruta.").font(.caption)
                        Text(shortcutsStatus).font(.footnote)
                    }
                    Section("Firma") { SigningPanel(); ClearSignSetupPanel(); ClearRecoveryExportPanel() }
                    Section("Diseño") {
                        Text("Referencias Clear Medium, Glass Small 7 y Clear Small de Lokki. Uso personal. No distribuir los recursos originales sin autorización.")
                    }
                }.navigationTitle("ClearWidget")
                    .onAppear { ClearSign.shared.update(); ClearSign.shared.schedule(); Task { await ClearSign.shared.refreshAlerts() } }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active {
                            ClearSign.shared.update(); ClearSign.shared.schedule()
                            Task { await ClearSign.shared.refreshAlerts() }
                            if locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways { locationStatus = "Ubicación autorizada." }
                        }
                    }
            }
        }
    }
}
