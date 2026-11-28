import SwiftUI
import WidgetKit

private enum LabVariant: String {
    case system = "CWLabSystem"
    case clear = "CWLabClear"
    case blur = "CWLabBlur"
    case glass = "CWLabGlass"

    var label: String {
        switch self {
        case .system: return "Sistema"
        case .clear: return "Clear"
        case .blur: return "Blur"
        case .glass: return "Cristal del sistema"
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
            if variant == .system {
                Color.gray.opacity(0.2)
            } else {
                Color.clear
            }
        }
    }
}

private struct LabWidget: Widget {
    let variant: LabVariant
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: variant.rawValue, provider: LabProvider()) { _ in
            LabContent(variant: variant)
        }
        .configurationDisplayName("Lab · " + variant.label)
        .description("Prueba independiente de material y renderizado.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .containerBackgroundRemovable(true)
        .widgetTexture(.glass)
    }
}

@main
struct NativeMaterialLabWidgets: WidgetBundle {
    init() { CWLabInstall() }
    var body: some Widget {
        LabWidget(variant: .system)
        LabWidget(variant: .clear)
        LabWidget(variant: .blur)
        LabWidget(variant: .glass)
    }
}
