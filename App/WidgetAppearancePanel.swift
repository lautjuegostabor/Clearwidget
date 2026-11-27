import SwiftUI
import WidgetKit

struct WidgetAppearancePanel: View {
    @State private var selected = AppearancePreference.current()
    @State private var status = "Sistema es el valor inicial."
    @State private var observation: Task<Void, Never>?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Section("Apariencia") {
            ForEach(WidgetAppearance.allCases, id: \.rawValue) { mode in
                Button {
                    apply(mode)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.label).foregroundStyle(.primary)
                            Text(mode.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: selected == mode ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected == mode ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("appearance.\(mode.rawValue)")
                .accessibilityAddTraits(selected == mode ? [.isSelected] : [])
            }
            Text(status).font(.footnote).accessibilityIdentifier("appearance.status")
            Button("Comprobar estado") { refreshStatus() }
            Text("La marca indica tu selección, no el efecto visual aplicado. Liquid Glass sigue siendo experimental y puede coincidir con Blur.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { selected = AppearancePreference.current(); refreshStatus() }
        .onChange(of: phase) { _, value in
            if value == .active { refreshStatus() }
            else { observation?.cancel(); observation = nil }
        }
        .onDisappear { observation?.cancel(); observation = nil }
    }
    @MainActor private func apply(_ mode: WidgetAppearance) {
        observation?.cancel()
        observation = nil
        selected = mode
        status = "Guardando \(mode.label)…"
        do {
            try AppearancePreference.select(mode)
            WidgetCenter.shared.invalidateConfigurationRecommendations()
            WidgetCenter.shared.reloadTimelines(ofKind: "ClearWidget")
            status = "Selección guardada. Actualización solicitada a iOS."
            observation = Task { @MainActor in
                for delay in [500, 1000, 2000, 3000] {
                    do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) } catch { return }
                    guard !Task.isCancelled else { return }
                    if refreshStatus() { return }
                }
            }
        } catch {
            status = "Selección local: \(mode.label). No se pudo enviar al widget: \(error.localizedDescription)"
        }
    }
    @MainActor @discardableResult private func refreshStatus() -> Bool {
        do {
            switch try AppearancePreference.delivery() {
            case .initial: status = "Sistema es el valor inicial."
            case .pending:
                status = "Selección guardada; todavía sin confirmación de WidgetKit."
                return false
            case .timelineReceived:
                status = "WidgetKit recibió la selección. iOS aún no volvió a solicitar el descriptor de fondo."
                return false
            case .system: status = "WidgetKit devolvió el descriptor original (Sistema)."
            case .patched: status = "Descriptor modificado y devuelto a iOS. Comprobá el resultado visual."
            case .rejected: status = "No se pudo modificar el descriptor. iOS conserva el original."
            case .hookUnavailable: status = "La API de descriptores no está disponible en esta instalación."
            }
        } catch {
            status = "No se pudo leer el estado compartido: \(error.localizedDescription)"
        }
        return true
    }
}
