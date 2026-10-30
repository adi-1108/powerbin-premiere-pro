import Foundation
import Combine

/// .clp file = JSON envelope, base64-encoded NSData blobs.
struct Preset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var tag: String?               // "red"|"orange"|"yellow"|"green"|"blue"|"purple"
    var createdAt: Date
    var types: [String: Data]      // uti -> bytes
    var typeOrder: [String]?
    var isFavorite: Bool
    var previewImageName: String?
    var url: URL?                  // on-disk path (not persisted)

    enum CodingKeys: String, CodingKey { case id, name, tag, createdAt, types, typeOrder, isFavorite, previewImageName }

    init(id: UUID = UUID(),
         name: String,
         tag: String? = nil,
         createdAt: Date = Date(),
         types: [String: Data],
         typeOrder: [String]? = nil,
         isFavorite: Bool = false,
         previewImageName: String? = nil,
         url: URL? = nil) {
        self.id = id
        self.name = name
        self.tag = tag
        self.createdAt = createdAt
        self.types = types
        self.typeOrder = typeOrder
        self.isFavorite = isFavorite
        self.previewImageName = previewImageName
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        types = try c.decode([String: Data].self, forKey: .types)
        typeOrder = try c.decodeIfPresent([String].self, forKey: .typeOrder)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        previewImageName = try c.decodeIfPresent(String.self, forKey: .previewImageName)
        url = nil
    }

    var totalBytes: Int {
        types.values.reduce(0) { $0 + $1.count }
    }

    var sortedTypeNames: [String] {
        types.keys.sorted()
    }
}

struct PresetWorkspace: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// A preset as it appears in the cross-workspace index (Favorites / Most Used).
///
/// `preset.types` is deliberately EMPTY here — see `reloadLibraryIndex`. Anything that
/// needs the actual clipboard payload must go through `PresetStore.payloadForRestore`,
/// which re-reads the file.
struct LibraryPreset: Identifiable, Equatable {
    let workspace: PresetWorkspace
    let preset: Preset

    var id: String {
        "\(workspace.id.uuidString):\(preset.id.uuidString)"
    }
}

/// Everything a `.clp` holds except the clipboard payload itself.
///
/// Decoding `Preset` base64-decodes every stored pasteboard type. For the library index
/// that is pure waste: the index is rebuilt on every save, delete, tag and favourite
/// toggle, across every workspace, and none of its consumers read the payload.
private struct PresetMetadata: Decodable {
    let id: UUID
    let name: String
    let tag: String?
    let createdAt: Date
    let typeOrder: [String]?
    let isFavorite: Bool
    let previewImageName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, tag, createdAt, typeOrder, isFavorite, previewImageName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        typeOrder = try c.decodeIfPresent([String].self, forKey: .typeOrder)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        previewImageName = try c.decodeIfPresent(String.self, forKey: .previewImageName)
    }

    func asPreset(url: URL) -> Preset {
        var preset = Preset(
            id: id,
            name: name,
            tag: tag,
            createdAt: createdAt,
            types: [:],
            typeOrder: typeOrder,
            isFavorite: isFavorite,
            previewImageName: previewImageName
        )
        preset.url = url
        return preset
    }
}

final class PresetStore: ObservableObject {
    @Published private(set) var workspaces: [PresetWorkspace] = []
    @Published private(set) var activeWorkspaceID: UUID?
    @Published private(set) var presets: [Preset] = []
    @Published private(set) var libraryPresets: [LibraryPreset] = []

    private let rootDirectory: URL
    private let directPresetDirectory: URL?
    private let workspacesDirectory: URL
    private let manifestURL: URL
    private let userDefaults: UserDefaults
    private let activeWorkspaceKey = "activeWorkspaceID"

    var directory: URL {
        if let directPresetDirectory {
            return directPresetDirectory
        }
        guard let workspace = activeWorkspace else {
            return workspacesDirectory
                .appendingPathComponent("default", isDirectory: true)
                .appendingPathComponent("presets", isDirectory: true)
        }
        return directory(for: workspace)
    }

    var activeWorkspace: PresetWorkspace? {
        guard let activeWorkspaceID else { return workspaces.first }
        return workspaces.first(where: { $0.id == activeWorkspaceID }) ?? workspaces.first
    }

    init(directory: URL? = nil) {
        if let d = directory {
            rootDirectory = d
            directPresetDirectory = d
            workspacesDirectory = d
            manifestURL = d.appendingPathComponent("workspaces.json")
            userDefaults = .standard
            workspaces = [PresetWorkspace(name: "Default")]
            activeWorkspaceID = workspaces.first?.id
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        } else {
            // Library lives in ~/Library/Application Support/PowerBin/.
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PowerBin", isDirectory: true)
            rootDirectory = support
            directPresetDirectory = nil
            workspacesDirectory = support.appendingPathComponent("workspaces", isDirectory: true)
            manifestURL = support.appendingPathComponent("workspaces.json")
            userDefaults = .standard
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: workspacesDirectory, withIntermediateDirectories: true)
            loadWorkspaces()
            ensureDefaultWorkspace()
            restoreActiveWorkspace()
            migrateLegacyPresetsIfNeeded()
        }
        reload()
    }

    // MARK: - List

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let clps = files.filter { $0.pathExtension == "clp" }
        var loaded: [Preset] = []
        for url in clps {
            if var p = try? load(url: url) {
                p.url = url
                loaded.append(p)
            }
        }
        loaded.sort { $0.createdAt > $1.createdAt }
        presets = loaded
        reloadLibraryIndex()
    }

    private func load(url: URL) throws -> Preset {
        let data = try Data(contentsOf: url)
        return try JSONDecoder.preset.decode(Preset.self, from: data)
    }

    func payloadForRestore(_ preset: Preset) -> Preset {
        guard let url = preset.url,
              var fresh = try? load(url: url) else {
            return preset
        }
        fresh.id = preset.id
        fresh.url = url
        return fresh
    }

    func libraryItem(for preset: Preset) -> LibraryPreset? {
        if let url = preset.url,
           let item = libraryPresets.first(where: { $0.preset.url == url }) {
            return item
        }
        guard let activeWorkspaceID else { return nil }
        return libraryPresets.first {
            $0.workspace.id == activeWorkspaceID && $0.preset.id == preset.id
        }
    }

    // MARK: - Mutate

    @discardableResult
    func save(name: String, types: [String: Data], typeOrder: [String]? = nil, tag: String? = nil) throws -> Preset {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = sanitizedFileName(name)
        var candidate = directory.appendingPathComponent(safe + ".clp")
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(safe)-\(i).clp")
            i += 1
        }
        var preset = Preset(name: name, tag: tag, createdAt: Date(), types: types, typeOrder: normalizedTypeOrder(typeOrder, for: types))
        try JSONEncoder.preset.encode(preset).write(to: candidate)
        preset.url = candidate
        presets.insert(preset, at: 0)
        // ponytail: full rescan, same as clearPreviewImage. The .clp is already on disk
        // by here. Swap for an incremental update if a big library makes the rescan bite.
        reloadLibraryIndex()
        return preset
    }

    func delete(_ preset: Preset) {
        if let preview = previewURL(for: preset) {
            try? FileManager.default.removeItem(at: preview)
        }
        if let url = preset.url { try? FileManager.default.removeItem(at: url) }
        presets.removeAll { $0.id == preset.id }
        reloadLibraryIndex()
    }

    func setTag(_ preset: Preset, tag: String?) {
        updatePreset(preset) { $0.tag = tag }
    }

    func toggleFavorite(_ preset: Preset) {
        updatePreset(preset) { $0.isFavorite.toggle() }
    }

    func previewURL(for preset: Preset) -> URL? {
        guard let imageName = preset.previewImageName else { return nil }
        let url = previewDirectory(for: preset).appendingPathComponent(imageName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func temporaryPreviewCaptureURL(for preset: Preset) throws -> URL {
        let dir = previewDirectory(for: preset)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("capture-\(UUID().uuidString).png")
    }

    @discardableResult
    func attachPreviewImage(_ preset: Preset, from sourceURL: URL, removeSource: Bool = false) throws -> Preset {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else {
            throw PresetStoreError.missingPreset
        }

        let dir = previewDirectory(for: presets[idx])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ext = normalizedImageExtension(sourceURL.pathExtension)
        let filename = "\(preset.id.uuidString)-\(UUID().uuidString).\(ext)"
        let target = dir.appendingPathComponent(filename)

        if removeSource {
            try FileManager.default.moveItem(at: sourceURL, to: target)
        } else {
            try FileManager.default.copyItem(at: sourceURL, to: target)
        }

        if let existing = presets[idx].previewImageName {
            let existingURL = dir.appendingPathComponent(existing)
            if existingURL.path != target.path {
                try? FileManager.default.removeItem(at: existingURL)
            }
        }

        presets[idx].previewImageName = filename
        try persistPreset(at: idx)
        reloadLibraryIndex()
        return presets[idx]
    }

    func clearPreviewImage(_ preset: Preset) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        if let existing = presets[idx].previewImageName {
            try? FileManager.default.removeItem(at: previewDirectory(for: presets[idx]).appendingPathComponent(existing))
        }
        presets[idx].previewImageName = nil
        try? persistPreset(at: idx)
        reloadLibraryIndex()
    }

    // MARK: - Workspaces

    @discardableResult
    func createWorkspace(name: String) -> PresetWorkspace? {
        guard directPresetDirectory == nil else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let workspace = PresetWorkspace(name: trimmed)
        workspaces.append(workspace)
        saveWorkspaces()
        selectWorkspace(workspace)
        return workspace
    }

    func renameWorkspace(_ workspace: PresetWorkspace, name: String) {
        guard directPresetDirectory == nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[idx].name = trimmed
        saveWorkspaces()
        reloadLibraryIndex()
    }

    func deleteWorkspace(_ workspace: PresetWorkspace) {
        guard directPresetDirectory == nil, workspaces.count > 1 else { return }
        if let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            let folder = workspaceFolder(for: workspace)
            try? FileManager.default.removeItem(at: folder)
            workspaces.remove(at: idx)
            if activeWorkspaceID == workspace.id {
                activeWorkspaceID = workspaces.first?.id
                persistActiveWorkspace()
                reload()
            }
            saveWorkspaces()
            reloadLibraryIndex()
        }
    }

    func selectWorkspace(_ workspace: PresetWorkspace) {
        guard activeWorkspaceID != workspace.id else { return }
        activeWorkspaceID = workspace.id
        persistActiveWorkspace()
        reload()
    }

    // MARK: - Private

    private func updatePreset(_ preset: Preset, mutate: (inout Preset) -> Void) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        mutate(&presets[idx])
        try? persistPreset(at: idx)
        reloadLibraryIndex()
    }

    /// Rebuilds the cross-workspace index used by Favorites and Most Used.
    ///
    /// Metadata only. This runs on every save, delete, tag change and favourite toggle, and
    /// it used to decode the full `Preset` for every `.clp` in every workspace — which
    /// base64-decodes each stored Premiere payload and then keeps all of them resident. On
    /// a real library (a hundred presets, a megabyte or two each) that is hundreds of MB of
    /// RAM and a visible stall every time the user clicks a star.
    ///
    /// Nothing downstream reads `types` from these: the rows show a name, a workspace and a
    /// usage count, and pasting re-reads the file through `payloadForRestore`.
    private func reloadLibraryIndex() {
        var loaded: [LibraryPreset] = []

        for workspace in workspaces {
            let presetDirectory = directPresetDirectory ?? directory(for: workspace)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: presetDirectory,
                includingPropertiesForKeys: nil
            )) ?? []

            for url in files where url.pathExtension == "clp" {
                guard let data = try? Data(contentsOf: url),
                      let meta = try? JSONDecoder.preset.decode(PresetMetadata.self, from: data) else {
                    continue
                }
                loaded.append(LibraryPreset(workspace: workspace, preset: meta.asPreset(url: url)))
            }
        }

        libraryPresets = loaded.sorted { lhs, rhs in
            if lhs.preset.createdAt == rhs.preset.createdAt {
                return lhs.preset.name.localizedCaseInsensitiveCompare(rhs.preset.name) == .orderedAscending
            }
            return lhs.preset.createdAt > rhs.preset.createdAt
        }
    }

    private func persistPreset(at index: Int) throws {
        guard presets.indices.contains(index), let url = presets[index].url else { return }
        try JSONEncoder.preset.encode(presets[index]).write(to: url)
    }

    private func normalizedImageExtension(_ ext: String) -> String {
        let cleaned = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["jpg", "jpeg", "png", "heic", "heif", "tiff", "gif"].contains(cleaned) {
            return cleaned == "jpeg" ? "jpg" : cleaned
        }
        return "png"
    }

    private func previewDirectory(for preset: Preset) -> URL {
        if let url = preset.url {
            let presetDirectory = url.deletingLastPathComponent()
            if presetDirectory.lastPathComponent == "presets" {
                return presetDirectory.deletingLastPathComponent().appendingPathComponent("previews", isDirectory: true)
            }
            return presetDirectory.appendingPathComponent("previews", isDirectory: true)
        }

        if directPresetDirectory != nil {
            return directory.appendingPathComponent("previews", isDirectory: true)
        }

        if let workspace = activeWorkspace {
            return workspaceFolder(for: workspace).appendingPathComponent("previews", isDirectory: true)
        }

        return workspacesDirectory
            .appendingPathComponent("default", isDirectory: true)
            .appendingPathComponent("previews", isDirectory: true)
    }

    private func sanitizedFileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return safe.isEmpty ? "Preset" : safe
    }

    private func normalizedTypeOrder(_ typeOrder: [String]?, for types: [String: Data]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for uti in typeOrder ?? [] where types[uti] != nil && !seen.contains(uti) {
            ordered.append(uti)
            seen.insert(uti)
        }

        for uti in types.keys.sorted() where !seen.contains(uti) {
            ordered.append(uti)
            seen.insert(uti)
        }

        return ordered
    }

    private func loadWorkspaces() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder.preset.decode([PresetWorkspace].self, from: data) else {
            workspaces = []
            return
        }
        workspaces = decoded.sorted { $0.createdAt < $1.createdAt }
    }

    private func saveWorkspaces() {
        guard directPresetDirectory == nil else { return }
        try? JSONEncoder.preset.encode(workspaces).write(to: manifestURL)
    }

    private func ensureDefaultWorkspace() {
        if workspaces.isEmpty {
            workspaces = [PresetWorkspace(name: "Default")]
            saveWorkspaces()
        }
        for workspace in workspaces {
            try? FileManager.default.createDirectory(at: directory(for: workspace), withIntermediateDirectories: true)
        }
    }

    private func restoreActiveWorkspace() {
        if let idString = userDefaults.string(forKey: activeWorkspaceKey),
           let id = UUID(uuidString: idString),
           workspaces.contains(where: { $0.id == id }) {
            activeWorkspaceID = id
        } else {
            activeWorkspaceID = workspaces.first?.id
            persistActiveWorkspace()
        }
    }

    private func persistActiveWorkspace() {
        if let activeWorkspaceID {
            userDefaults.set(activeWorkspaceID.uuidString, forKey: activeWorkspaceKey)
        }
    }

    private func migrateLegacyPresetsIfNeeded() {
        guard directPresetDirectory == nil,
              let defaultWorkspace = workspaces.first else { return }
        let legacy = rootDirectory.appendingPathComponent("presets", isDirectory: true)
        let legacyFiles = ((try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "clp" }
        guard !legacyFiles.isEmpty else { return }

        let destination = directory(for: defaultWorkspace)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in legacyFiles {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.copyItem(at: file, to: target)
            }
        }
    }

    private func workspaceFolder(for workspace: PresetWorkspace) -> URL {
        workspacesDirectory.appendingPathComponent(workspace.id.uuidString, isDirectory: true)
    }

    private func directory(for workspace: PresetWorkspace) -> URL {
        workspaceFolder(for: workspace).appendingPathComponent("presets", isDirectory: true)
    }
}

enum PresetStoreError: LocalizedError {
    case missingPreset

    var errorDescription: String? {
        switch self {
        case .missingPreset:
            return "Preset was not found."
        }
    }
}

private extension JSONEncoder {
    static let preset: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
private extension JSONDecoder {
    static let preset: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
