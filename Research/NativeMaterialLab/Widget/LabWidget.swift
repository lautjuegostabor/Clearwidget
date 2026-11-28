import AppIntents
import SwiftUI
import WidgetKit

private enum LabVariant: String {
    case exact = "CWLabExactGlass"
    case exactLight6 = "CWLabExactGlassLight6"
    case exactLight12 = "CWLabExactGlassLight12"
    case exactLight20 = "CWLabExactGlassLight20"
    case exactLight30 = "CWLabExactGlassLight30"
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

    var lightening: Double {
        switch self {
        case .exactLight6: return 0.06
        case .exactLight12: return 0.12
        case .exactLight20: return 0.20
        case .exactLight30: return 0.30
        default: return 0
        }
    }

    var label: String {
        switch self {
        case .exact: return "Cristal original"
        case .exactLight6: return "Cristal +6%"
        case .exactLight12: return "Cristal +12%"
        case .exactLight20: return "Cristal +20%"
        case .exactLight30: return "Cristal +30%"
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
        .background {
            // Keep host-rendered Solarium; compensate luminance in the foreground
            // so WidgetKit cannot discard it as a removable container background.
            if variant.lightening > 0 {
                Color.white.opacity(variant.lightening)
                    .allowsHitTesting(false)
            }
        }
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

private struct ExactMaterialIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Cristal original"
}
private struct ExactMaterialProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LabEntry { LabEntry(date: .now) }
    func snapshot(for configuration: ExactMaterialIntent, in context: Context) async -> LabEntry { LabEntry(date: .now) }
    func timeline(for configuration: ExactMaterialIntent, in context: Context) async -> Timeline<LabEntry> {
        Timeline(entries: [LabEntry(date: .now)], policy: .never)
    }
}
private struct ExactGlassLabWidget: Widget {
    let variant: LabVariant
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: variant.rawValue, intent: ExactMaterialIntent.self, provider: ExactMaterialProvider()) { _ in
            LabContent(variant: variant)
        }
        .configurationDisplayName("Lab · " + variant.label)
        .description("Cristal nativo con compensación de luminosidad opcional.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}
@main
struct NativeMaterialLabWidgets: WidgetBundle {
    init() { CWLabInstall() }
    var body: some Widget {
        ExactGlassLabWidget(variant: .exact)
        ExactGlassLabWidget(variant: .exactLight6)
        ExactGlassLabWidget(variant: .exactLight12)
        ExactGlassLabWidget(variant: .exactLight20)
        ExactGlassLabWidget(variant: .exactLight30)
        SystemLabWidget()
        ClearLabWidget()
        BlurLabWidget()
        HostGlassSmallLabWidget()
        HostGlassMediumLabWidget()
    }
}
