import AppKit
import SwiftUI

struct PresetRow: View {
    let preset: Preset
    let isSelected: Bool
    let previewURL: URL?
    let onSelect: (Preset) -> Void
    let onLoad: (Preset) -> Void
    let onPaste: (Preset) -> Void
    let onDelete: (Preset) -> Void
    let onTag: (Preset, String?) -> Void
    let onToggleFavorite: (Preset) -> Void

    private static let tagColors: [(String, Color)] = [
        ("red", .red), ("orange", .orange), ("yellow", .yellow),
        ("green", .green), ("blue", .blue), ("purple", .purple),
    ]

    var body: some View {
        HStack(spacing: 10) {
            presetThumbnail

            Rectangle()
                .fill(color(for: preset.tag))
                .frame(width: 3, height: 40)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(preset.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if preset.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                    }
                }
                Text("\(preset.types.count) type(s) · \(byteString(preset.totalBytes)) · \(dateText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                onToggleFavorite(preset)
            } label: {
                Image(systemName: preset.isFavorite ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .help(preset.isFavorite ? "Remove favorite" : "Add favorite")
            .accessibilityLabel(preset.isFavorite
                                ? "Remove \(preset.name) from favorites"
                                : "Add \(preset.name) to favorites")

            Button {
                onLoad(preset)
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .help("Load onto clipboard")
            .accessibilityLabel("Load \(preset.name) onto the clipboard")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner)
                .fill(isSelected ? Theme.selectionFill : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner)
                .stroke(isSelected ? Theme.selectionStroke : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        // Double-tap MUST be declared before single-tap. SwiftUI resolves tap gestures in
        // the order they are attached, so with the single-tap first it always wins and the
        // count: 2 gesture never fires — which meant double-clicking a preset selected it
        // instead of pasting it into Premiere, the app's headline interaction.
        .onTapGesture(count: 2) { onPaste(preset) }
        .onTapGesture { onSelect(preset) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Double-tap to paste this preset into Premiere Pro.")
        .contextMenu {
            Button("Paste to Premiere") {
                onPaste(preset)
            }
            Button("Load Clipboard Only") {
                onLoad(preset)
            }
            Divider()
            Button(preset.isFavorite ? "Remove Favorite" : "Add Favorite") {
                onToggleFavorite(preset)
            }
            Menu("Set Tag") {
                ForEach(Self.tagColors, id: \.0) { name, _ in
                    Button(name.capitalized) { onTag(preset, name) }
                }
                Divider()
                Button("Clear Tag") { onTag(preset, nil) }
            }
            Divider()
            Button("Delete", role: .destructive) { onDelete(preset) }
        }
    }

    @ViewBuilder
    private var presetThumbnail: some View {
        // Decoded once and cached — see PreviewImageCache. This was `NSImage(contentsOf:)`
        // inline, i.e. a disk read and a full-size PNG decode per row per render pass.
        if let image = PreviewImageCache.shared.thumbnail(for: previewURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.surfaceStrong)
                .frame(width: 52, height: 36)
                .overlay(
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                )
                .accessibilityHidden(true)
        }
    }

    private var accessibilityDescription: String {
        var parts = [preset.name]
        if preset.isFavorite { parts.append("favorite") }
        if let tag = preset.tag { parts.append("\(tag) tag") }
        parts.append("\(preset.types.count) clipboard types")
        parts.append(byteString(preset.totalBytes))
        return parts.joined(separator: ", ")
    }

    private var dateText: String {
        Self.rowDateFormatter.string(from: preset.createdAt)
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func color(for tag: String?) -> Color {
        guard let tag = tag,
              let pair = Self.tagColors.first(where: { $0.0 == tag }) else {
            return .clear
        }
        return pair.1
    }

    private static let rowDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
