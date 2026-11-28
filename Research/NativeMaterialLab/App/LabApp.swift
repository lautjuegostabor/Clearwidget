import SwiftUI
import WidgetKit

@main
struct MaterialLabApp: App {
    var body: some Scene {
        WindowGroup { LabView() }
    }
}

private struct LabView: View {
    @State private var result = "Sin consultar"
    var body: some View {
        NavigationStack {
            List {
                Section("Comparación aislada") {
                    Text("Sistema: fondo normal.")
                    Text("Clear: descriptor transparente, estilo 1.")
                    Text("Blur: descriptor translúcido, estilo 2.")
                    Text("Cristal del sistema: textura pública de WidgetKit. Depende del modo de inicio de iOS.")
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
                Section("Alcance") {
                    Text("Proyecto de investigación independiente. No cambia el aspecto de ClearWidget. No usa capturas del fondo, IPC ni cuentas Apple.")
                    Text("La presencia de un widget no demuestra que SpringBoard acepte su descriptor.")
                }
            }.navigationTitle("Laboratorio de material")
        }
    }
}
