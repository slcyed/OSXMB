import SwiftUI
import AppKit

struct GalleryView: View {
    @ObservedObject var model: GalleryModel
    let onApply: (XMBVariant) -> Void

    private var previewVariant: XMBVariant {
        model.hoveredVariant ?? model.currentVariant ?? model.variants[0]
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                previewHeader
                Divider()
                grid
            }
        }
        .frame(minWidth: 900, minHeight: 620)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("OSXMB")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("PlayStation-inspired live wallpaper")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 18)

            TextField("Search variants", text: $model.searchText)
                .textFieldStyle(.roundedBorder)

            Text("FAMILIES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            List(selection: $model.selectedFamily) {
                ForEach(model.families, id: \.self) { family in
                    Text(family)
                        .tag(family)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Spacer(minLength: 8)
            Text("\(model.filtered.count) of \(model.variants.count) variants")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Rendered live with Metal. Click a tile to apply.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .background(.regularMaterial)
    }

    private var previewHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(previewVariant.name)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("\(previewVariant.subtitle) · live hover preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.appliedID == previewVariant.id {
                    Label("Applied", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
                Button("Apply to Desktop") {
                    apply(previewVariant)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }

            LivePreviewRepresentable(variant: previewVariant)
                .frame(height: 250)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        }
        .padding(16)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 12)], spacing: 12) {
                ForEach(model.filtered) { variant in
                    VariantTile(
                        variant: variant,
                        isApplied: model.appliedID == variant.id,
                        isHovered: model.hoveredVariant?.id == variant.id,
                        onHover: { hovering in
                            if hovering {
                                model.hoveredVariant = variant
                            }
                        },
                        onSelect: { apply(variant) }
                    )
                }
            }
            .padding(16)
        }
    }

    private func apply(_ variant: XMBVariant) {
        model.markApplied(variant)
        onApply(variant)
    }
}

private struct VariantTile: View {
    let variant: XMBVariant
    let isApplied: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .bottomLeading) {
                GradientSwatch(gradient: variant.gradient)
                WaveAccent()
                    .opacity(0.5)
                LinearGradient(
                    colors: [.clear, .black.opacity(0.62)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(variant.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(variant.family)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .foregroundStyle(.white)
                .padding(9)
            }
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isHovered || isApplied ? Color.accentColor : Color.white.opacity(0.1),
                                  lineWidth: isHovered || isApplied ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if isApplied {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white, .green)
                        .padding(7)
                }
            }
            .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .help(variant.name)
    }
}

private struct GradientSwatch: View {
    let gradient: XMBGradient

    var body: some View {
        let rad = Double(gradient.angleDeg) * .pi / 180
        let dx = cos(rad)
        let dy = sin(rad)
        LinearGradient(
            colors: [gradient.start.color, gradient.end.color],
            startPoint: UnitPoint(x: 0.5 - 0.5 * dx, y: 0.5 - 0.5 * dy),
            endPoint: UnitPoint(x: 0.5 + 0.5 * dx, y: 0.5 + 0.5 * dy)
        )
    }
}

private struct WaveAccent: View {
    var body: some View {
        Canvas { context, size in
            let width = Double(size.width)
            let height = Double(size.height)
            for band in 0..<3 {
                var path = Path()
                let amplitude = height * (0.035 + Double(band) * 0.012)
                let baseline = height * (0.48 + Double(band) * 0.12)
                for step in 0...64 {
                    let x = width * Double(step) / 64
                    let y = baseline + amplitude * sin(Double(step) * 0.22 + Double(band) * 1.3)
                    if step == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(path, with: .color(.white.opacity(0.26 - Double(band) * 0.06)),
                               lineWidth: 1.1)
            }
        }
        .allowsHitTesting(false)
    }
}

struct LivePreviewRepresentable: NSViewRepresentable {
    let variant: XMBVariant

    func makeNSView(context: Context) -> LiveWallpaperView {
        LiveWallpaperView(variant: variant, antiAliasing: .current)
    }

    func updateNSView(_ nsView: LiveWallpaperView, context: Context) {
        nsView.update(variant: variant)
        nsView.setAntiAliasing(.current)
    }
}
