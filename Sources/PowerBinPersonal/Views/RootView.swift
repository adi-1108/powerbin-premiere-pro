import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Floating panel content: workspaces, search, preset list, preview, and Save.
struct RootView: View {
    @ObservedObject var store: PresetStore
    let pasteboard: PasteboardService
    let dismiss: () -> Void
    let reveal: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var usageStore = PresetUsageStore()
    @State private var search = ""
    @State private var nameDraft = ""
    @State private var workspaceDraft = ""
    @State private var showSavePrompt = false
    @State private var workspaceEditMode: WorkspaceEditMode?
    @State private var statusMessage = ""
    @State private var selectedPresetID: Preset.ID?
    @State private var sortMode: PresetSort = .dateCreated
    @State private var rightSidebarTab: RightSidebarTab = .preview
    @State private var isRightSidebarExpanded = true
    @State private var isCapturingPreview = false
    @State private var activeCaptureToken: UUID?
    /// Kept so a user-cancelled capture restores the clipboard the same way a timeout does.
    @State private var clipboardBeforeActiveCapture: [String: Data] = [:]
    @State private var statusClearToken = UUID()
    @State private var keyMonitor: Any?
    @FocusState private var focusedField: Field?

    private enum Field {
        case search
        case saveName
        case workspaceName
    }

    private enum WorkspaceEditMode {
        case create
        case rename(PresetWorkspace)
    }

    private enum RightSidebarTab: String, CaseIterable, Identifiable {
        case preview
        case favorites
        case mostUsed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .preview: return "Preview"
            case .favorites: return "Favorites"
            case .mostUsed: return "Most Used"
            }
        }

        var icon: String {
            switch self {
            case .preview: return "sidebar.right"
            case .favorites: return "star.fill"
            case .mostUsed: return "chart.bar.fill"
            }
        }
    }

    private enum PresetSort: String, CaseIterable, Identifiable {
        case dateCreated
        case timeCreated
        case name
        case size
        case kind

        var id: String { rawValue }

        var label: String {
            switch self {
            case .dateCreated: return "Date Created"
            case .timeCreated: return "Time Created"
            case .name: return "Name"
            case .size: return "Size"
            case .kind: return "Kind"
            }
        }

        var icon: String {
            switch self {
            case .dateCreated: return "calendar"
            case .timeCreated: return "clock"
            case .name: return "textformat"
            case .size: return "externaldrive"
            case .kind: return "doc.on.doc"
            }
        }
    }

    private var visiblePresets: [Preset] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var items = store.presets

        if !q.isEmpty {
            items = items.filter { preset in
                preset.name.lowercased().contains(q)
                    || (preset.tag?.lowercased().contains(q) ?? false)
                    || preset.sortedTypeNames.contains { $0.lowercased().contains(q) }
            }
        }

        return sorted(items)
    }

    private var selectedPreset: Preset? {
        guard let selectedPresetID else { return nil }
        return store.presets.first(where: { $0.id == selectedPresetID })
    }

    private var favoriteLibraryPresets: [LibraryPreset] {
        store.libraryPresets
            .filter { $0.preset.isFavorite }
            .sorted { lhs, rhs in
                let lhsCount = usageStore.count(for: lhs)
                let rhsCount = usageStore.count(for: rhs)
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                return lhs.preset.name.localizedCaseInsensitiveCompare(rhs.preset.name) == .orderedAscending
            }
    }

    private var mostUsedLibraryPresets: [LibraryPreset] {
        store.libraryPresets
            .filter { usageStore.count(for: $0) > 0 }
            .sorted { lhs, rhs in
                let lhsCount = usageStore.count(for: lhs)
                let rhsCount = usageStore.count(for: rhs)
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                return (usageStore.lastUsedAt(for: lhs) ?? .distantPast)
                    > (usageStore.lastUsedAt(for: rhs) ?? .distantPast)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if workspaceEditMode != nil {
                workspaceEditor
                    .transition(.move(edge: .top).combined(with: .opacity))
                Divider()
            }
            if showSavePrompt {
                saveEditor
                    .transition(.move(edge: .top).combined(with: .opacity))
                Divider()
            }
            content
            Divider()
            footer
        }
        .background(.ultraThinMaterial)
        .cornerRadius(Theme.panelCorner)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelCorner).stroke(Theme.hairline))
        .motion(Motion.quick, value: showSavePrompt)
        .motion(Motion.quick, value: workspaceEditMode != nil)
        .motion(Motion.panel, value: isRightSidebarExpanded)
        .motion(Motion.quick, value: rightSidebarTab)
        .motion(Motion.quick, value: selectedPresetID)
        .onChange(of: statusMessage) { _ in scheduleStatusClear() }
        .onAppear {
            installKeyMonitor()
            // The panel is a launcher; land in the filter field so typing works straight
            // away instead of after a click.
            DispatchQueue.main.async { focusedField = .search }
        }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Filter presets...", text: $search)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .search)
                .onSubmit { submitFromSearch() }
                .accessibilityLabel("Filter presets")
                .accessibilityHint("Use the up and down arrow keys to pick a preset, then Return to paste it.")

            if !search.isEmpty {
                Button {
                    withMotion { search = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }

            sortMenu

            Button {
                promptSave()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .accessibilityLabel("Save the current clipboard as a preset")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(PresetSort.allCases) { mode in
                Button {
                    sortMode = mode
                } label: {
                    Label(mode.label, systemImage: mode == sortMode ? "checkmark" : mode.icon)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .buttonStyle(.borderless)
        .help("Sort presets")
        .accessibilityLabel("Sort presets. Currently \(sortMode.label).")
    }

    private var workspaceEditor: some View {
        HStack(spacing: 8) {
            Image(systemName: workspaceEditIcon)
                .foregroundStyle(.secondary)
            TextField(workspacePlaceholder, text: $workspaceDraft)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .workspaceName)
                .onSubmit { commitWorkspaceEdit() }
            Button("Cancel") { cancelWorkspaceEdit() }
                .buttonStyle(.borderless)
            Button(workspaceCommitTitle) { commitWorkspaceEdit() }
                .keyboardShortcut(.defaultAction)
                .disabled(workspaceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear {
            DispatchQueue.main.async {
                focusedField = .workspaceName
            }
        }
    }

    private var saveEditor: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down")
                .foregroundStyle(.secondary)
            TextField("Preset name", text: $nameDraft)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .saveName)
                .onSubmit { performSave() }
            Button("Cancel") { cancelSave() }
                .buttonStyle(.borderless)
            Button("Create") { performSave() }
                .keyboardShortcut(.defaultAction)
                .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear {
            DispatchQueue.main.async {
                focusedField = .saveName
            }
        }
    }

    private var content: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
            Divider()
            presetList
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            rightSidebar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .frame(minWidth: 720, minHeight: 420)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Workspaces")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    beginWorkspaceCreate()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Client Workspace")
                .accessibilityLabel("New workspace")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(store.workspaces) { workspace in
                        workspaceRow(workspace)
                    }

                    Divider()
                        .padding(.vertical, 6)

                    Text("Sort By")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 2)

                    ForEach(PresetSort.allCases) { mode in
                        Button {
                            sortMode = mode
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: mode.icon)
                                Text(mode.label)
                                    .lineLimit(1)
                                Spacer()
                                if mode == sortMode {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 4)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.65))
    }

    private func workspaceRow(_ workspace: PresetWorkspace) -> some View {
        HStack(spacing: 6) {
            Button {
                withMotion {
                    store.selectWorkspace(workspace)
                    selectedPresetID = nil
                }
                statusMessage = "Switched to \(workspace.name)."
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                    Text(workspace.name)
                        .lineLimit(1)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Workspace \(workspace.name)")
            .accessibilityAddTraits(store.activeWorkspace?.id == workspace.id
                                    ? [.isButton, .isSelected] : .isButton)

            if store.activeWorkspace?.id == workspace.id {
                Menu {
                    Button("Rename Workspace") {
                        beginWorkspaceRename()
                    }
                    Button("Delete Workspace", role: .destructive) {
                        deleteActiveWorkspace()
                    }
                    .disabled(store.workspaces.count <= 1)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help("Workspace Settings")
                .accessibilityLabel("Workspace options for \(workspace.name)")
                .padding(.trailing, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner)
                .fill(store.activeWorkspace?.id == workspace.id ? Theme.sidebarSelection : Color.clear)
        )
        .padding(.horizontal, 4)
    }

    private var presetList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if visiblePresets.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text(emptyMessage)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(24)
                    } else {
                        ForEach(visiblePresets) { preset in
                            PresetRow(
                                preset: preset,
                                isSelected: selectedPresetID == preset.id,
                                previewURL: store.previewURL(for: preset),
                                onSelect: select,
                                onLoad: load,
                                onPaste: pastePreset,
                                onDelete: delete,
                                onTag: tag,
                                onToggleFavorite: favorite
                            )
                            .id(preset.id)
                            .padding(.horizontal, 8)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            // Keeps the arrow-key selection on screen.
            .onChange(of: selectedPresetID) { id in
                guard let id else { return }
                withMotion { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .accessibilityLabel("Presets in \(store.activeWorkspace?.name ?? "Default")")
    }

    private var rightSidebar: some View {
        HStack(spacing: 0) {
            if isRightSidebarExpanded {
                rightSidebarContent
                    .frame(width: 310)
                    .frame(maxHeight: .infinity)
                Divider()
            }

            rightSidebarRail
                .frame(width: 46)
                .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var rightSidebarContent: some View {
        switch rightSidebarTab {
        case .preview:
            ScrollView {
                previewPane
            }
        case .favorites:
            quickAccessPane(
                title: "Favorites",
                icon: "star.fill",
                items: favoriteLibraryPresets,
                emptyMessage: "Favorite presets from any workspace appear here."
            )
        case .mostUsed:
            quickAccessPane(
                title: "Most Used",
                icon: "chart.bar.fill",
                items: mostUsedLibraryPresets,
                emptyMessage: "Presets appear here after you load or paste them."
            )
        }
    }

    private var rightSidebarRail: some View {
        VStack(spacing: 6) {
            ForEach(RightSidebarTab.allCases) { tab in
                Button {
                    selectRightSidebarTab(tab)
                } label: {
                    Image(systemName: tab.icon)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(rightSidebarTab == tab && isRightSidebarExpanded
                                      ? Color.accentColor.opacity(0.2)
                                      : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(isRightSidebarExpanded && rightSidebarTab == tab
                      ? "Hide \(tab.title)"
                      : "Show \(tab.title)")
                .accessibilityLabel(isRightSidebarExpanded && rightSidebarTab == tab
                                    ? "Hide \(tab.title)"
                                    : "Show \(tab.title)")
                .accessibilityAddTraits(rightSidebarTab == tab && isRightSidebarExpanded
                                        ? [.isButton, .isSelected] : .isButton)
            }

            Spacer()

            Button {
                withMotion(Motion.panel) { isRightSidebarExpanded.toggle() }
            } label: {
                Image(systemName: isRightSidebarExpanded ? "chevron.right" : "chevron.left")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isRightSidebarExpanded ? "Collapse sidebar" : "Expand sidebar")
            .accessibilityLabel(isRightSidebarExpanded ? "Collapse sidebar" : "Expand sidebar")
        }
        .padding(.vertical, 10)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.65))
    }

    private func quickAccessPane(title: String,
                                 icon: String,
                                 items: [LibraryPreset],
                                 emptyMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            if items.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: icon)
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(items) { item in
                            quickAccessRow(item)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    private func quickAccessRow(_ item: LibraryPreset) -> some View {
        HStack(spacing: 9) {
            quickAccessThumbnail(item)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.preset.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(item.workspace.name)
                        .lineLimit(1)
                    if usageStore.count(for: item) > 0 {
                        Text("· \(usageStore.count(for: item)) uses")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button {
                pasteLibraryPreset(item)
            } label: {
                Image(systemName: "arrowshape.turn.up.right")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Paste to Premiere")
            .accessibilityLabel("Paste \(item.preset.name) into Premiere Pro")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner)
                .fill(Theme.surface)
        )
        .contentShape(Rectangle())
        // Double-tap before single-tap — with the order reversed the single tap always
        // wins and the double never fires. Same bug as PresetRow.
        .onTapGesture(count: 2) {
            pasteLibraryPreset(item)
        }
        .onTapGesture {
            openLibraryPreset(item)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.preset.name), in \(item.workspace.name)")
        .accessibilityHint("Double-tap to paste into Premiere Pro.")
        .contextMenu {
            Button("Paste to Premiere") {
                pasteLibraryPreset(item)
            }
            Button("Open Workspace") {
                openLibraryPreset(item)
            }
        }
    }

    @ViewBuilder
    private func quickAccessThumbnail(_ item: LibraryPreset) -> some View {
        if let image = PreviewImageCache.shared.thumbnail(for: store.previewURL(for: item.preset)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.surfaceStrong)
                .frame(width: 48, height: 34)
                .overlay(
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                )
                .accessibilityHidden(true)
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let preset = selectedPreset {
                previewHeader(preset)
                Divider()
                previewImage(preset)
                previewActions(preset)
                Divider()
                previewMetadata(preset)
                Divider()
                previewTypes(preset)
            } else {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "sidebar.right")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Select a preset to preview its stored clipboard data.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(14)
    }

    private func previewHeader(_ preset: Preset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                Button {
                    favorite(preset)
                } label: {
                    Image(systemName: preset.isFavorite ? "star.fill" : "star")
                }
                .buttonStyle(.borderless)
                .help(preset.isFavorite ? "Remove favorite" : "Add favorite")
                .accessibilityLabel(preset.isFavorite ? "Remove from favorites" : "Add to favorites")
                Button {
                    load(preset)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .help("Load onto clipboard")
                .accessibilityLabel("Load onto the clipboard")
                Button {
                    pastePreset(preset)
                } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                }
                .buttonStyle(.borderless)
                .help("Paste to Premiere")
                .accessibilityLabel("Paste into Premiere Pro")
            }
            Text(preset.name)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(2)
        }
    }

    private func previewImage(_ preset: Preset) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.previewWell)

            if let image = PreviewImageCache.shared.preview(for: store.previewURL(for: preset)) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
                    .accessibilityLabel("Screenshot preview for \(preset.name)")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No screenshot preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.hairline, lineWidth: 1)
        )
    }

    private func previewActions(_ preset: Preset) -> some View {
        VStack(spacing: 8) {
            Button {
                uploadPreview(for: preset)
            } label: {
                Label("Upload Screenshot", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("Upload a screenshot preview")

            Button {
                capturePreview(for: preset)
            } label: {
                Label(isCapturingPreview ? "Waiting for Screenshot…" : "Capture Screenshot", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isCapturingPreview)
            .help("Capture a screenshot preview")

            // Without this, cancelling the macOS screenshot left the button disabled and
            // "Capturing…" on screen until the poll timed out, with no way to get out of it.
            if isCapturingPreview {
                Button {
                    cancelCapture()
                } label: {
                    Label("Cancel Capture", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button {
                attachClipboardPreview(for: preset)
            } label: {
                Label("Use Copied Screenshot", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("Use an image currently copied to the clipboard")

            if store.previewURL(for: preset) != nil {
                Button {
                    clearPreview(for: preset)
                } label: {
                    Label("Remove Preview", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
    }

    private func previewMetadata(_ preset: Preset) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            metadataRow("Workspace", store.activeWorkspace?.name ?? "Default")
            metadataRow("Created", Self.dateFormatter.string(from: preset.createdAt))
            metadataRow("Time", Self.timeFormatter.string(from: preset.createdAt))
            metadataRow("Size", byteString(preset.totalBytes))
            metadataRow("Kinds", "\(preset.types.count) clipboard type(s)")
            metadataRow("Preview", store.previewURL(for: preset) == nil ? "None" : "Screenshot")
            if let tag = preset.tag {
                metadataRow("Tag", tag.capitalized)
            }
            metadataRow("Favorite", preset.isFavorite ? "Yes" : "No")
        }
    }

    private func previewTypes(_ preset: Preset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stored Types")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(preset.sortedTypeNames, id: \.self) { type in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(type)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                            Text(byteString(preset.types[type]?.count ?? 0))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surface))
                    }
                }
            }
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack {
            Text(statusMessage.isEmpty ? "\(store.activeWorkspace?.name ?? "Default") · \(store.presets.count) preset(s)" : statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(statusMessage)
                // Announce results (saved, pasted, failed) without the user hunting for
                // the status line.
                .accessibilityAddTraits(.updatesFrequently)
            Spacer()
            Text(AppInfo.shortVersion)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Version \(AppInfo.shortVersion)")
            Button("Prefs") { SettingsWindowController.shared.show() }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityLabel("Open Preferences")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func selectRightSidebarTab(_ tab: RightSidebarTab) {
        withMotion(Motion.panel) {
            if rightSidebarTab == tab && isRightSidebarExpanded {
                isRightSidebarExpanded = false
            } else {
                rightSidebarTab = tab
                isRightSidebarExpanded = true
            }
        }
    }

    private func openLibraryPreset(_ item: LibraryPreset) {
        withMotion {
            store.selectWorkspace(item.workspace)
            selectedPresetID = item.preset.id
            rightSidebarTab = .preview
            isRightSidebarExpanded = true
        }
        statusMessage = "Opened '\(item.preset.name)' in \(item.workspace.name)."
    }

    // MARK: - Status line

    /// Clears the status line a few seconds after it is set. It used to stay on screen
    /// forever, so "Clipboard empty. Cmd-C in Premiere first." was still sitting under a
    /// successfully saved preset ten minutes later.
    private func scheduleStatusClear() {
        guard !statusMessage.isEmpty else { return }
        let token = UUID()
        statusClearToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard statusClearToken == token else { return }
            withMotion { statusMessage = "" }
        }
    }

    // MARK: - Keyboard

    /// ↑ / ↓ move the selection and ⏎ pastes it, from anywhere in the panel including
    /// while typing in the filter field — which is where a launcher's hands actually are.
    ///
    /// A local monitor rather than `onMoveCommand` because the filter field holds focus and
    /// would otherwise swallow the arrows. Guarded on the key window being the panel, so a
    /// monitor that outlives an `orderOut` can never eat keys meant for Preferences.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.keyWindow is FloatingPanel,
                  workspaceEditMode == nil,
                  !showSavePrompt else { return event }

            switch event.keyCode {
            case 126: moveSelection(by: -1); return nil   // ↑
            case 125: moveSelection(by: 1);  return nil   // ↓
            case 36, 76:                                  // ⏎ / numpad ⏎
                guard let preset = selectedPreset else { return event }
                pastePreset(preset)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func moveSelection(by offset: Int) {
        let items = visiblePresets
        guard !items.isEmpty else { return }
        guard let current = selectedPresetID,
              let index = items.firstIndex(where: { $0.id == current }) else {
            selectedPresetID = items.first?.id
            return
        }
        let next = min(max(index + offset, 0), items.count - 1)
        selectedPresetID = items[next].id
    }

    /// Return in the filter field: paste the highlighted preset if there is one, otherwise
    /// fall back to the first match.
    private func submitFromSearch() {
        if let preset = selectedPreset, visiblePresets.contains(where: { $0.id == preset.id }) {
            pastePreset(preset)
        } else {
            loadFirst()
        }
    }

    private func pasteLibraryPreset(_ item: LibraryPreset) {
        pastePreset(item.preset)
    }

    private func beginWorkspaceCreate() {
        workspaceDraft = ""
        withMotion { workspaceEditMode = .create }
        statusMessage = ""
    }

    private func beginWorkspaceRename() {
        guard let workspace = store.activeWorkspace else { return }
        workspaceDraft = workspace.name
        withMotion { workspaceEditMode = .rename(workspace) }
        statusMessage = ""
    }

    private func commitWorkspaceEdit() {
        let name = workspaceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        switch workspaceEditMode {
        case .create:
            if let workspace = store.createWorkspace(name: name) {
                selectedPresetID = nil
                statusMessage = "Created workspace \(workspace.name)."
            }
        case .rename(let workspace):
            store.renameWorkspace(workspace, name: name)
            statusMessage = "Renamed workspace to \(name)."
        case .none:
            break
        }

        cancelWorkspaceEdit()
    }

    private func cancelWorkspaceEdit() {
        withMotion { workspaceEditMode = nil }
        workspaceDraft = ""
        focusedField = .search
    }

    private func deleteActiveWorkspace() {
        guard let workspace = store.activeWorkspace else { return }
        store.deleteWorkspace(workspace)
        selectedPresetID = nil
        statusMessage = "Deleted workspace \(workspace.name)."
    }

    private func promptSave() {
        nameDraft = defaultName()
        statusMessage = ""
        withMotion { showSavePrompt = true }
        Log.line(" save prompt opened")
    }

    private func performSave() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            statusMessage = "Name the preset first."
            return
        }

        let allTypes = pasteboard.listTypes()
        let snap = pasteboard.snapshotPayload(adobeOnly: settings.adobeOnlySnapshot)
        Log.line(" save requested — workspace=\(store.activeWorkspace?.name ?? "Default") adobeOnly=\(settings.adobeOnlySnapshot) pasteboardTypes=\(allTypes.count) savedTypes=\(snap.types.count) order=\(snap.orderedTypes.count) \(PasteboardService.summary(snap.types))")
        guard !snap.types.isEmpty else {
            if settings.adobeOnlySnapshot && !allTypes.isEmpty {
                statusMessage = "No Adobe/Premiere clipboard types found. Turn off Adobe-only or copy in Premiere."
            } else {
                statusMessage = "Clipboard empty. Cmd-C in Premiere first."
            }
            return
        }
        do {
            let preset = try store.save(name: name, types: snap.types, typeOrder: snap.orderedTypes)
            withMotion {
                showSavePrompt = false
                selectedPresetID = preset.id
            }
            focusedField = .search
            statusMessage = "Saved '\(preset.name)' in \(store.activeWorkspace?.name ?? "Default")."
            Log.line(" save succeeded — name=\(preset.name) types=\(snap.types.count) order=\(snap.orderedTypes.count)")
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
            Log.line(" save failed — \(error)")
        }
    }

    private func cancelSave() {
        withMotion { showSavePrompt = false }
        focusedField = .search
    }

    private func select(_ preset: Preset) {
        selectedPresetID = preset.id
    }

    private func load(_ preset: Preset) {
        selectedPresetID = preset.id
        if settings.autoPasteAfterLoad {
            recordUsage(of: preset)
            statusMessage = "Pasting '\(preset.name)' into Premiere."
            dismiss()
            runPasteDriverRestoringPreset(preset, reason: "auto-paste")
        } else {
            guard writePresetToPasteboard(preset, reason: "load") else { return }
            recordUsage(of: preset)
            statusMessage = "Loaded '\(preset.name)'. Cmd-V in Premiere."
        }
    }

    private func pastePreset(_ preset: Preset) {
        let mode = currentPasteMode
        guard PermissionsService.status(.accessibility) == .granted else {
            selectedPresetID = preset.id
            _ = writePresetToPasteboard(preset, reason: "blocked-paste")
            statusMessage = "Accessibility is required to press the paste shortcut in Premiere."
            Log.line(" preset double-click blocked — accessibility denied")
            return
        }

        selectedPresetID = preset.id
        recordUsage(of: preset)
        statusMessage = "Pasting '\(preset.name)' into Premiere."
        Log.line(" preset double-click paste — name=\(preset.name) mode=\(mode.rawValue) combo=\(pasteComboDescription(for: mode)) restoreTiming=after-focus")
        dismiss()
        runPasteDriverRestoringPreset(preset, reason: mode.rawValue)
    }

    @discardableResult
    private func writePresetToPasteboard(_ preset: Preset, reason: String) -> Bool {
        let payload = store.payloadForRestore(preset)

        // `payloadForRestore` falls back to the in-memory preset when the .clp can't be
        // re-read, and library-index presets carry no payload by design. Writing that would
        // clear the user's real clipboard and paste nothing — refuse instead.
        guard !payload.types.isEmpty else {
            statusMessage = "Could not read '\(payload.name)' from disk. Clipboard left alone."
            Log.line(" pasteboard restore \(reason) ABORTED — empty payload for name=\(payload.name) file=\(payload.url?.lastPathComponent ?? "memory")")
            return false
        }

        let report = pasteboard.write(payload.types, typeOrder: payload.typeOrder)
        Log.line(" pasteboard restore \(reason) — name=\(payload.name) file=\(payload.url?.lastPathComponent ?? "memory") \(PasteboardService.summary(payload.types)) order=\(payload.typeOrder?.count ?? 0) declared=\(report.declaredTypes.count) aliases=\(report.aliasTypes.count) omitted=\(report.omittedTypes) change=\(report.changeCount) verified=\(report.isVerified) setFailures=\(report.setFailures) verifyFailures=\(report.verificationFailures)")
        if report.isVerified {
            return true
        }

        statusMessage = "Clipboard restore failed for '\(payload.name)'. See log."
        return false
    }

    private func runPasteDriverRestoringPreset(_ preset: Preset, reason: String) {
        Log.line(" paste activating Premiere before clipboard restore — name=\(preset.name) reason=\(reason)")
        let restore: (String) -> Bool = { restoreReason in
            selectedPresetID = preset.id
            return writePresetToPasteboard(preset, reason: restoreReason)
        }
        PasteDriver.run(
            settings: settings,
            beforeInjection: {
                restore("\(reason)-after-focus")
            },
            beforeExcaliburReturn: {
                restore("\(reason)-before-return")
            }
        )
    }

    private var currentPasteMode: PasteMode {
        if let raw = UserDefaults.standard.string(forKey: "pasteMode"),
           let mode = PasteMode(rawValue: raw) {
            return mode
        }
        return settings.pasteMode
    }

    private func pasteComboDescription(for mode: PasteMode) -> String {
        switch mode {
        case .native:
            return "cmd+v"
        case .excalibur:
            return settings.excaliburHotkey
        case .custom:
            return settings.customPasteHotkey
        }
    }

    private func loadFirst() {
        guard let first = visiblePresets.first else { return }
        load(first)
    }

    private func delete(_ preset: Preset) {
        store.delete(preset)
        if selectedPresetID == preset.id {
            selectedPresetID = nil
        }
    }

    private func tag(_ preset: Preset, _ tag: String?) {
        store.setTag(preset, tag: tag)
    }

    private func favorite(_ preset: Preset) {
        store.toggleFavorite(preset)
    }

    private func recordUsage(of preset: Preset) {
        guard let item = store.libraryItem(for: preset) else { return }
        usageStore.recordUse(item)
    }

    private func uploadPreview(for preset: Preset) {
        selectedPresetID = preset.id
        let panel = NSOpenPanel()
        panel.title = "Choose Preview Screenshot"
        panel.prompt = "Use Screenshot"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let updated = try store.attachPreviewImage(preset, from: url)
            selectedPresetID = updated.id
            statusMessage = "Added screenshot preview for '\(updated.name)'."
            Log.line(" preview upload succeeded — name=\(updated.name) file=\(url.lastPathComponent)")
        } catch {
            statusMessage = "Preview upload failed: \(error.localizedDescription)"
            Log.line(" preview upload failed — \(error)")
        }
    }

    private func capturePreview(for preset: Preset) {
        guard !isCapturingPreview else { return }
        selectedPresetID = preset.id
        isCapturingPreview = true
        let token = UUID()
        activeCaptureToken = token
        let startedAt = Date()
        let startingPasteboardChangeCount = NSPasteboard.general.changeCount
        let clipboardBeforeCapture = pasteboard.snapshot(adobeOnly: false)
        clipboardBeforeActiveCapture = clipboardBeforeCapture
        statusMessage = "Use the macOS screenshot toolbar. PowerBin will attach the screenshot automatically."
        Log.line(" preview capture starting — name=\(preset.name)")
        dismiss()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            launchScreenshotApp { error in
                if let error {
                    isCapturingPreview = false
                    activeCaptureToken = nil
                    clipboardBeforeActiveCapture = [:]
                    statusMessage = "Preview capture failed: \(error.localizedDescription)"
                    Log.line(" preview capture launch failed — \(error)")
                    reveal()
                    return
                }

                pollForCapturedPreview(
                    preset,
                    token: token,
                    startedAt: startedAt,
                    startingPasteboardChangeCount: startingPasteboardChangeCount,
                    clipboardBeforeCapture: clipboardBeforeCapture,
                    // 60s at 0.5s per poll. Was 90s, which is a long time to sit with the
                    // Capture button disabled if the screenshot was cancelled.
                    attemptsRemaining: 120
                )
            }
        }
    }

    /// Abandon a capture the user has walked away from, and put their clipboard back.
    private func cancelCapture() {
        guard isCapturingPreview else { return }
        isCapturingPreview = false
        activeCaptureToken = nil
        restoreClipboard(clipboardBeforeActiveCapture)
        clipboardBeforeActiveCapture = [:]
        statusMessage = "Screenshot capture cancelled."
        Log.line(" preview capture cancelled by user")
    }

    private func attachClipboardPreview(for preset: Preset) {
        selectedPresetID = preset.id
        guard let pngData = screenshotPNGDataFromPasteboard() else {
            statusMessage = "No copied screenshot found on the clipboard."
            Log.line(" preview clipboard attach failed — no image data")
            return
        }

        do {
            let targetURL = try store.temporaryPreviewCaptureURL(for: preset)
            try pngData.write(to: targetURL, options: .atomic)
            let updated = try store.attachPreviewImage(preset, from: targetURL, removeSource: true)
            selectedPresetID = updated.id
            statusMessage = "Added copied screenshot preview for '\(updated.name)'."
            Log.line(" preview clipboard attach succeeded — name=\(updated.name)")
        } catch {
            statusMessage = "Copied screenshot failed: \(error.localizedDescription)"
            Log.line(" preview clipboard attach failed — \(error)")
        }
    }

    private func clearPreview(for preset: Preset) {
        store.clearPreviewImage(preset)
        selectedPresetID = preset.id
        statusMessage = "Removed screenshot preview for '\(preset.name)'."
    }

    private func launchScreenshotApp(completion: @escaping (Error?) -> Void) {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            DispatchQueue.main.async {
                completion(error)
            }
        }
    }

    private func pollForCapturedPreview(_ preset: Preset,
                                        token: UUID,
                                        startedAt: Date,
                                        startingPasteboardChangeCount: Int,
                                        clipboardBeforeCapture: [String: Data],
                                        attemptsRemaining: Int) {
        guard activeCaptureToken == token else { return }

        if NSPasteboard.general.changeCount != startingPasteboardChangeCount,
           let pngData = screenshotPNGDataFromPasteboard() {
            finishClipboardCapture(
                preset,
                token: token,
                pngData: pngData,
                clipboardBeforeCapture: clipboardBeforeCapture
            )
            return
        }

        if let fileURL = newestScreenshotFile(after: startedAt) {
            finishFileCapture(preset, token: token, fileURL: fileURL, clipboardBeforeCapture: clipboardBeforeCapture)
            return
        }

        guard attemptsRemaining > 0 else {
            isCapturingPreview = false
            activeCaptureToken = nil
            restoreClipboard(clipboardBeforeCapture)
            clipboardBeforeActiveCapture = [:]
            statusMessage = "Screenshot capture timed out."
            Log.line(" preview capture timed out")
            reveal()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pollForCapturedPreview(
                preset,
                token: token,
                startedAt: startedAt,
                startingPasteboardChangeCount: startingPasteboardChangeCount,
                clipboardBeforeCapture: clipboardBeforeCapture,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private func finishClipboardCapture(_ preset: Preset,
                                        token: UUID,
                                        pngData: Data,
                                        clipboardBeforeCapture: [String: Data]) {
        do {
            let targetURL = try store.temporaryPreviewCaptureURL(for: preset)
            try pngData.write(to: targetURL, options: .atomic)
            let updated = try store.attachPreviewImage(preset, from: targetURL, removeSource: true)
            restoreClipboard(clipboardBeforeCapture)
            finishCaptureSuccess(updated, message: "Captured screenshot preview")
        } catch {
            restoreClipboard(clipboardBeforeCapture)
            finishCaptureFailure(error)
        }
    }

    private func finishFileCapture(_ preset: Preset,
                                   token: UUID,
                                   fileURL: URL,
                                   clipboardBeforeCapture: [String: Data]) {
        do {
            let updated = try store.attachPreviewImage(preset, from: fileURL)
            restoreClipboard(clipboardBeforeCapture)
            finishCaptureSuccess(updated, message: "Captured screenshot preview")
        } catch {
            restoreClipboard(clipboardBeforeCapture)
            finishCaptureFailure(error)
        }
    }

    private func finishCaptureSuccess(_ preset: Preset, message: String) {
        isCapturingPreview = false
        activeCaptureToken = nil
        clipboardBeforeActiveCapture = [:]
        selectedPresetID = preset.id
        statusMessage = "\(message) for '\(preset.name)'."
        Log.line(" preview capture succeeded — name=\(preset.name)")
        reveal()
    }

    private func finishCaptureFailure(_ error: Error) {
        isCapturingPreview = false
        activeCaptureToken = nil
        clipboardBeforeActiveCapture = [:]
        statusMessage = "Preview capture failed: \(error.localizedDescription)"
        Log.line(" preview capture attach failed — \(error)")
        reveal()
    }

    private func screenshotPNGDataFromPasteboard() -> Data? {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: NSPasteboard.PasteboardType("public.png")) {
            return data
        }
        if let data = pb.data(forType: .tiff) {
            return pngData(fromImageData: data)
        }
        if let image = pb.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let tiff = image.tiffRepresentation {
            return pngData(fromImageData: tiff)
        }
        return nil
    }

    private func pngData(fromImageData data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    private func restoreClipboard(_ snapshot: [String: Data]) {
        if snapshot.isEmpty {
            pasteboard.clear()
        } else {
            _ = pasteboard.write(snapshot)
        }
    }

    private func newestScreenshotFile(after start: Date) -> URL? {
        let cutoff = start.addingTimeInterval(-1)
        var candidates: [(url: URL, modified: Date)] = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]

        for directory in screenshotSearchDirectories() {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in urls where isScreenshotImage(url) {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      modified >= cutoff else {
                    continue
                }
                candidates.append((url, modified))
            }
        }

        return candidates.sorted { $0.modified > $1.modified }.first?.url
    }

    private func screenshotSearchDirectories() -> [URL] {
        var urls: [URL] = []

        if let configured = CFPreferencesCopyAppValue(
            "location" as CFString,
            "com.apple.screencapture" as CFString
        ) as? String {
            let expanded = NSString(string: configured).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                urls.append(url)
            }
        }

        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            urls.append(desktop)
        }

        return Array(Set(urls))
    }

    private func isScreenshotImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "heif", "tiff", "gif"].contains(ext)
    }

    private func sorted(_ presets: [Preset]) -> [Preset] {
        switch sortMode {
        case .dateCreated:
            return presets.sorted {
                if Calendar.current.startOfDay(for: $0.createdAt) != Calendar.current.startOfDay(for: $1.createdAt) {
                    return $0.createdAt > $1.createdAt
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .timeCreated:
            return presets.sorted {
                let lhs = secondsInDay($0.createdAt)
                let rhs = secondsInDay($1.createdAt)
                if lhs != rhs { return lhs > rhs }
                return $0.createdAt > $1.createdAt
            }
        case .name:
            return presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size:
            return presets.sorted {
                if $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .kind:
            return presets.sorted {
                if $0.types.count != $1.types.count { return $0.types.count > $1.types.count }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    private func secondsInDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    }

    private func defaultName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Preset \(f.string(from: Date()))"
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var emptyMessage: String {
        if store.presets.isEmpty { return "No presets yet. Cmd-C in Premiere, then click Save." }
        return "No matches."
    }

    private var workspaceEditIcon: String {
        switch workspaceEditMode {
        case .create: return "folder.badge.plus"
        case .rename: return "pencil"
        case .none: return "folder"
        }
    }

    private var workspacePlaceholder: String {
        switch workspaceEditMode {
        case .create: return "Client or workspace name"
        case .rename: return "Workspace name"
        case .none: return "Workspace name"
        }
    }

    private var workspaceCommitTitle: String {
        switch workspaceEditMode {
        case .create: return "Create"
        case .rename: return "Rename"
        case .none: return "Save"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
