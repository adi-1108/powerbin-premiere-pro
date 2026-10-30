import AppKit
import UniformTypeIdentifiers

struct PasteboardSnapshot {
    let types: [String: Data]
    let orderedTypes: [String]
}

struct PasteboardWriteReport {
    let changeCount: Int
    let declaredTypes: [String]
    let aliasTypes: [String: String]
    let omittedTypes: [String]
    let setFailures: [String]
    let verificationFailures: [String]

    var isVerified: Bool {
        setFailures.isEmpty && verificationFailures.isEmpty
    }
}

/// NSPasteboard snapshot + restore. Mirrors Windows OpenClipboard / GetClipboardData / SetClipboardData.
final class PasteboardService {
    private let pb: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pb = pasteboard
    }

    // MARK: - Read

    func listTypes() -> [String] {
        (pb.types ?? []).map { $0.rawValue }
    }

    /// Returns {uti: bytes} for all types currently on the pasteboard.
    /// `adobeOnly` filters to `com.adobe.*` / anything containing "premiere".
    func snapshot(adobeOnly: Bool = false) -> [String: Data] {
        snapshotPayload(adobeOnly: adobeOnly).types
    }

    func snapshotPayload(adobeOnly: Bool = false) -> PasteboardSnapshot {
        var out: [String: Data] = [:]
        var ordered: [String] = []
        for uti in listTypes() {
            if adobeOnly && !Self.isAdobe(uti) { continue }
            if let data = pb.data(forType: NSPasteboard.PasteboardType(uti)) {
                out[uti] = data
                ordered.append(uti)
            }
        }
        return PasteboardSnapshot(types: out, orderedTypes: ordered)
    }

    // MARK: - Write

    @discardableResult
    func write(_ snapshot: [String: Data], typeOrder: [String]? = nil, verify: Bool = true) -> PasteboardWriteReport {
        _ = pb.clearContents()
        let omitted = snapshot.keys.filter { Self.isPremiereCookie($0) }.sorted()
        let writableSnapshot = snapshot.filter { !Self.isPremiereCookie($0.key) }
        let payload = writableSnapshot.isEmpty ? snapshot : writableSnapshot
        let ordered = orderedTypes(for: payload, typeOrder: typeOrder)
        let aliasPairs = adobeAliasPairs(for: payload, orderedTypes: ordered)
        let declared = declaredTypes(orderedTypes: ordered, aliasPairs: aliasPairs)
        let types = declared.map { NSPasteboard.PasteboardType($0) }
        let change = pb.declareTypes(types, owner: nil)

        var setFailures: [String] = []
        for uti in ordered {
            guard let data = payload[uti] else { continue }
            let didSet = pb.setData(data, forType: NSPasteboard.PasteboardType(uti))
            if !didSet {
                setFailures.append(uti)
            }
        }
        for (alias, source) in aliasPairs {
            guard let data = payload[source] else { continue }
            let didSet = pb.setData(data, forType: NSPasteboard.PasteboardType(alias))
            if !didSet {
                setFailures.append(alias)
            }
        }

        let verificationFailures = verify ? verificationFailures(for: payload, orderedTypes: ordered, aliasPairs: aliasPairs) : []
        return PasteboardWriteReport(
            changeCount: change,
            declaredTypes: declared,
            aliasTypes: aliasPairs,
            omittedTypes: omitted,
            setFailures: setFailures,
            verificationFailures: verificationFailures
        )
    }

    func clear() { pb.clearContents() }

    // MARK: -

    static func isAdobe(_ uti: String) -> Bool {
        let low = uti.lowercased()
        return low.hasPrefix("com.adobe.") || low.hasPrefix("adobe.") || low.contains("premiere")
    }

    static func isPremiereCookie(_ uti: String) -> Bool {
        if uti == "com.adobe.dvaui.ppro/mz/cookie" {
            return true
        }
        guard uti.hasPrefix("dyn."),
              let type = UTType(uti),
              type.preferredMIMEType == "com.adobe.dvaui.ppro/mz/cookie" else {
            return false
        }
        return true
    }

    static func summary(_ snapshot: [String: Data]) -> String {
        let totalBytes = snapshot.values.reduce(0) { $0 + $1.count }
        let typeSummary = snapshot.keys.sorted().map { "\($0):\(snapshot[$0]?.count ?? 0)" }.joined(separator: ",")
        return "types=\(snapshot.count) bytes=\(totalBytes) [\(typeSummary)]"
    }

    private func orderedTypes(for snapshot: [String: Data], typeOrder: [String]?) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for uti in typeOrder ?? [] where snapshot[uti] != nil && !seen.contains(uti) {
            ordered.append(uti)
            seen.insert(uti)
        }

        for uti in snapshot.keys.sorted() where !seen.contains(uti) {
            ordered.append(uti)
            seen.insert(uti)
        }

        return ordered
    }

    private func declaredTypes(orderedTypes: [String], aliasPairs: [String: String]) -> [String] {
        var seen = Set<String>()
        var declared: [String] = []

        for uti in orderedTypes {
            if let alias = aliasPairs.first(where: { $0.value == uti })?.key, !seen.contains(alias) {
                declared.append(alias)
                seen.insert(alias)
            }
            if !seen.contains(uti) {
                declared.append(uti)
                seen.insert(uti)
            }
        }

        for alias in aliasPairs.keys.sorted() where !seen.contains(alias) {
            declared.append(alias)
            seen.insert(alias)
        }

        return declared
    }

    private func adobeAliasPairs(for snapshot: [String: Data], orderedTypes: [String]) -> [String: String] {
        var aliases: [String: String] = [:]
        let existing = Set(snapshot.keys)
        for uti in orderedTypes {
            guard let alias = adobeAlias(for: uti), !existing.contains(alias) else { continue }
            aliases[alias] = uti
        }
        return aliases
    }

    private func adobeAlias(for uti: String) -> String? {
        guard uti.hasPrefix("dyn."),
              let type = UTType(uti),
              let mime = type.preferredMIMEType,
              Self.isAdobe(mime) else {
            return nil
        }
        return mime
    }

    private func verificationFailures(for snapshot: [String: Data], orderedTypes: [String], aliasPairs: [String: String]) -> [String] {
        var failures: [String] = []
        for uti in orderedTypes {
            let restored = pb.data(forType: NSPasteboard.PasteboardType(uti))
            if restored != snapshot[uti] {
                failures.append(uti)
            }
        }
        for (alias, source) in aliasPairs {
            let restored = pb.data(forType: NSPasteboard.PasteboardType(alias))
            if restored != snapshot[source] {
                failures.append(alias)
            }
        }
        return failures
    }
}
