import SwiftUI

@main
struct ClearWidgetApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("ClearWidget") {
                        Text("Agregá el widget mediano. En la pantalla de inicio, mantené pulsado ClearWidget y elegí Editar widget.")
                        Text("En Abrir Clima seleccioná la app Clima de Apple. En Abrir Calendario seleccioná Calendario. iOS abre la aplicación seleccionada directamente.")
                        Text("Elegí la apariencia Transparente de iOS para el cristal nativo.")
                    }
                    Section("Pronóstico") {
                        Text("Córdoba Capital · sin GPS · temperaturas en °C")
                        Link("Datos: Open-Meteo · ECMWF IFS 9 km", destination: URL(string: "https://open-meteo.com/")!)
                        Link("Modelo ECMWF", destination: URL(string: "https://www.ecmwf.int/")!)
                    }
                    Section("Diseño") {
                        Text("Referencia Clear Medium de Lokki. Uso personal. No distribuir los recursos originales sin autorización.")
                    }
                }.navigationTitle("ClearWidget")
            }
        }
    }
}
