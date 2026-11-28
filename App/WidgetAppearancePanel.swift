import SwiftUI
import WidgetKit

struct WidgetAppearancePanel: View {
    @State private var selected = AppearancePreference.current()
    @State private var status = "Sistema es el valor inicial."
    @State private var observation: Task<Void, Never>?
    @State private var descriptorStatus = "Sin solicitud a ChronoServices."
    @State private var transportStatus = ""
    @State private var reloadID = UUID()
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
            Text(descriptorStatus).font(.footnote).accessibilityIdentifier("appearance.readback")
            if !transportStatus.isEmpty { Text(transportStatus).font(.caption).foregroundStyle(.secondary) }
            Button("Comprobar estado") { _ = refreshStatus() }
            Text("Liquid Glass prueba el material nativo de SwiftUI, sin fondo de pantalla. La confirmación del descriptor no demuestra refracción óptica.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { selected = AppearancePreference.current(); restoreAndRefresh() }
        .onChange(of: phase) { _, value in
            if value == .active { restoreAndRefresh() }
            else { observation?.cancel(); observation = nil }
        }
        .onDisappear { observation?.cancel(); observation = nil }
    }
    @MainActor private func restoreAndRefresh() {
        do {
            selected = AppearancePreference.current()
            let restored = try AppearancePreference.restoreRequest()
            if restored {
                WidgetCenter.shared.invalidateConfigurationRecommendations()
                WidgetCenter.shared.reloadTimelines(ofKind:"ClearWidget")
            }
            if restored { requestDescriptorReload() }
            refreshStatus()
        } catch { status = "No se pudo enviar la selección: \(error.localizedDescription)"; transportStatus = AppearancePreference.transportStatus() }
    }
    @MainActor private func apply(_ mode: WidgetAppearance) {
        observation?.cancel()
        observation = nil
        selected = mode
        reloadID = UUID()
        descriptorStatus = "Selección nueva; lectura pendiente."
        status = "Guardando \(mode.label)…"
        do {
            try AppearancePreference.select(mode)
            WidgetCenter.shared.invalidateConfigurationRecommendations()
            WidgetCenter.shared.reloadTimelines(ofKind: "ClearWidget")
            requestDescriptorReload()
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
            transportStatus = AppearancePreference.transportStatus()
        }
    }
    @MainActor private func requestDescriptorReload() {
        let id = UUID()
        reloadID = id
        let mode = selected
        descriptorStatus = "Solicitando recarga del descriptor…"
        let expected = mode == .system ? -1 : (mode == .blur ? 2 : 1)
        CWReloadOwnDescriptors(expected) { message in
            Task { @MainActor in
                guard reloadID == id else { return }
                descriptorStatus = message
                _ = refreshStatus()
            }
        }
    }
    @MainActor @discardableResult private func refreshStatus() -> Bool {
        transportStatus = AppearancePreference.transportStatus()
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
