import SwiftUI
import WidgetKit

struct WidgetAppearancePanel: View {
    @State private var confirmed: WidgetAppearance?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Section("Apariencia") {
            ForEach(WidgetAppearance.allCases, id: \.rawValue) { mode in
                Button(intent: SelectWidgetAppearance(mode)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.label).foregroundStyle(.primary)
                            Text(mode.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if confirmed == mode {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                .accessibilityLabel("Selección recibida por WidgetKit")
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Text("Sistema es el valor inicial. El cambio se guarda en la extensión y se solicita una actualización a iOS. Liquid Glass y Blur pueden coincidir: no se fuerza la apariencia general.")
                .font(.caption)
            Button("Consultar selección recibida") { confirmed = AppearancePreference.confirmedInWidget() }
            Text(confirmed.map { "WidgetKit recibió: \($0.label). No confirma el efecto visual." } ?? "Sin confirmación compartida. La selección puede estar guardada en la extensión aunque este diagnóstico no pueda leerla.")
                .font(.caption)
        }
        .onAppear { confirmed = AppearancePreference.confirmedInWidget() }
        .onChange(of: phase) { _, value in
            if value == .active { confirmed = AppearancePreference.confirmedInWidget() }
        }
    }
}
