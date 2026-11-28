import SwiftUI
import WidgetKit

private enum LabVariant: String {
    case system = "CWLabSystem"
    case clear = "CWLabClear"
    case blur = "CWLabBlur"
    case glass = "CWLabGlass"
    case clear08 = "CWLabClearTint08"
    case clear16 = "CWLabClearTint16"
    case lightBlur50 = "CWLabLightBlur50"
    case lightBlur85 = "CWLabLightBlur85"
    case hostGlassSmall = "CWLabNativeSDKSmall"
    case hostGlassMedium = "CWLabNativeSDKMedium"

    var label: String {
        switch self {
        case .system: return "Sistema"
        case .clear: return "Clear"
        case .blur: return "Blur"
        case .glass: return "Cristal del sistema"
        case .clear08: return "Clear + 8%"
        case .clear16: return "Clear + 16%"
        case .lightBlur50: return "Blur suave 50%"
        case .lightBlur85: return "Blur suave 85%"
        case .hostGlassSmall, .hostGlassMedium: return "Material de Apple"
        }
    }
}

private struct LabEntry: TimelineEntry { let date: Date }
private struct LabProvider: TimelineProvider {
    func placeholder(in context: Context) -> LabEntry { LabEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (LabEntry) -> Void) {
        completion(LabEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LabEntry>) -> Void) {
        completion(Timeline(entries: [LabEntry(date: Date())], policy: .never))
    }
}

private struct LabContent: View {
    let variant: LabVariant
    @Environment(\.widgetRenderingMode) private var rendering
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    private var renderingName: String {
        switch rendering {
        case .fullColor: return "fullColor"
        case .accented: return "accented"
        case .vibrant: return "vibrant"
        default: return "otro"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.title2)
            Text(variant.label).font(.headline)
            Text(renderingName).font(.caption.monospaced())
            Text(showsBackground ? "Fondo visible" : "Fondo oculto").font(.caption2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) {
            switch variant {
            case .system:
                Color.gray.opacity(0.2)
            case .clear08:
                Color.white.opacity(0.08)
            case .clear16:
                Color.white.opacity(0.16)
            case .lightBlur50:
                Rectangle().fill(.ultraThinMaterial).opacity(0.50)
            case .lightBlur85:
                Rectangle().fill(.ultraThinMaterial).opacity(0.85)
            default:
                Color.clear
            }
        }
    }
}

private func labConfiguration(_ variant: LabVariant) -> some WidgetConfiguration {
    StaticConfiguration(kind: variant.rawValue, provider: LabProvider()) { _ in
        LabContent(variant: variant)
    }
    .configurationDisplayName("Lab · " + variant.label)
    .description("Prueba independiente de material y renderizado.")
    .supportedFamilies([.systemSmall, .systemMedium])
    .containerBackgroundRemovable(true)
}

private struct SystemLabWidget: Widget {
    var body: some WidgetConfiguration { labConfiguration(.system) }
}
private struct ClearLabWidget: Widget {
    var body: some WidgetConfiguration { labConfiguration(.clear) }
}
private struct BlurLabWidget: Widget {
    var body: some WidgetConfiguration { labConfiguration(.blur) }
}
private struct Clear08LabWidget: Widget {
    var body: some WidgetConfiguration { labConfiguration(.clear08) }
}
private struct Clear16LabWidget: Widget {
    var body: some WidgetConfiguration { labConfiguration(.clear16) }
}
private struct LightBlur50LabWidget: Widget {
    var body: some WidgetConfiguration { labConfiguration(.lightBlur50) }
}
private struct LightBlur85LabWidget: Widget {
    var body: some WidgetConfiguration { labConfiguration(.lightBlur85) }
}
private struct GlassLabWidget: Widget {
    var body: some WidgetConfiguration { labConfiguration(.glass) }
}

// Native WidgetKit configuration; neither kind enters the legacy descriptor patch.
private func hostGlassConfiguration(_ variant: LabVariant, family: WidgetFamily) -> some WidgetConfiguration {
    StaticConfiguration(kind: variant.rawValue, provider: LabProvider()) { _ in
        LabContent(variant: variant)
    }
    .configurationDisplayName(family == .systemSmall ? "Lab · Material Apple S" : "Lab · Material Apple M")
    .description("Solicita únicamente el material del sistema, sin filtros de SwiftUI.")
    .supportedFamilies([family])
    .preferredBackgroundStyle(.blur)
}
private struct HostGlassSmallLabWidget: Widget {
    var body: some WidgetConfiguration { hostGlassConfiguration(.hostGlassSmall, family: .systemSmall) }
}
private struct HostGlassMediumLabWidget: Widget {
    var body: some WidgetConfiguration { hostGlassConfiguration(.hostGlassMedium, family: .systemMedium) }
}

@main
struct NativeMaterialLabWidgets: WidgetBundle {
    init() { CWLabInstall() }
    var body: some Widget {
        SystemLabWidget()
        ClearLabWidget()
        Clear08LabWidget()
        Clear16LabWidget()
        LightBlur50LabWidget()
        LightBlur85LabWidget()
        BlurLabWidget()
        GlassLabWidget()
        HostGlassSmallLabWidget()
        HostGlassMediumLabWidget()
    }
}
