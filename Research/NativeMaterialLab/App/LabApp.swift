import SwiftUI
import WidgetKit
import UIKit

@main
struct MaterialLabApp: App {
    var body: some Scene {
        WindowGroup { LabView() }
    }
}

private struct LabView: View {
    @State private var result = "Sin consultar"
    @State private var inventory = ""
    var body: some View {
        NavigationStack {
            List {
                Section("Comparación aislada") {
                    Text("Sistema: fondo normal.")
                    Text("Clear: descriptor transparente, estilo 1.")
                    Text("Blur: descriptor translúcido, estilo 2.")
                    Text("Clear + 8% / + 16%: transparencia real con una capa blanca ligera.")
                    Text("Blur suave 50% / 85%: Clear con Ultra Thin Material de SwiftUI al 50% o 85% de opacidad; no modifica el radio fijo de Blur del host. Comprueba su aspecto en inicio.")
                    Text("Cristal del sistema y Material Apple S/M: referencias previas.")
                }
                Section("Estado de WidgetKit") {
                    Button("Consultar widgets añadidos") {
                        WidgetCenter.shared.getCurrentConfigurations { response in
                            DispatchQueue.main.async {
                                switch response {
                                case .success(let widgets):
                                    result = widgets.map { $0.kind }.sorted().joined(separator:"\n")
                                    if result.isEmpty { result = "Ninguno añadido." }
                                case .failure(let error): result = error.localizedDescription
                                }
                            }
                        }
                    }
                    Text(result).font(.footnote)
                }
                Section("Diagnóstico de cristal · 0.1.5") {
                    Button("Inspeccionar ChronoServices") { inventory = CWLabRuntimeInventory() }
                    Text("Consulta firmas y objetos temporales de color. No cambia la apariencia ni envía parámetros a SpringBoard.").font(.caption)
                    if !inventory.isEmpty {
                        Button("Copiar informe") { UIPasteboard.general.string = inventory }
                        Text(inventory).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
                Section("Alcance") {
                    Text("Proyecto de investigación independiente. No cambia el aspecto de ClearWidget. No usa capturas del fondo, IPC ni cuentas Apple.")
                    Text("La presencia de un widget no demuestra que SpringBoard acepte su descriptor.")
                }
            }.navigationTitle("Laboratorio de material")
        }
    }
}
