import SwiftUI

@main
struct ClearWidgetApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("ClearWidget") {
                        Text("Agregá Clear Medium o Glass Small 7 desde la galería de widgets. Mantené pulsado el widget y elegí Editar widget.")
                        Text("En Clear Medium podés configurar Acción principal, Abrir Clima y Abrir Calendario. En Glass Small 7 podés configurar Acción al tocar. Sin asignar no se abre ninguna app.")
                        Text("Elegí la apariencia Transparente de iOS para el cristal nativo.")
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
