import SwiftUI

/// Onboarding panel — lists every permission PowerBin needs, with live status
/// and a Grant button per row.
struct PermissionsView: View {
    @State private var statuses: [PermissionKind: PermissionStatus] = [:]
    let onDismiss: () -> Void

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "lock.shield")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Grant Permissions").font(.title2.bold())
                    Text("PowerBin needs these to control Premiere Pro and listen for hotkeys.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Divider()

            ForEach(PermissionKind.allCases) { kind in
                permissionRow(kind)
            }

            // macOS does not always re-evaluate a TCC grant for an already-running process,
            // and Input Monitoring in particular usually needs a relaunch. Saying so here
            // is the difference between "granted it, still broken, asking for a refund" and
            // one restart.
            Label("If a permission still shows as missing after you grant it, quit PowerBin from the menu bar and open it again.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack {
                Button("Skip for now") { onDismiss() }
                    .accessibilityHint("You can grant these later from Preferences.")
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 400)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func permissionRow(_ k: PermissionKind) -> some View {
        let s = statuses[k] ?? .unknown
        return HStack(spacing: 12) {
            statusBadge(s)
            VStack(alignment: .leading, spacing: 2) {
                Text(k.label).font(.headline)
                Text(k.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if s == .granted {
                Text("Granted").foregroundStyle(.green).font(.caption.bold())
            } else {
                Button("Grant") {
                    PermissionsService.request(k)
                    // Most prompts only fire once; also open Settings as a fallback.
                    PermissionsService.openSettings(k)
                }
                .accessibilityLabel("Grant \(k.label) permission")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(k.label): \(spoken(s)). \(k.reason)")
    }

    private func spoken(_ s: PermissionStatus) -> String {
        switch s {
        case .granted: return "granted"
        case .denied:  return "not granted"
        case .unknown: return "not determined"
        }
    }

    @ViewBuilder
    private func statusBadge(_ s: PermissionStatus) -> some View {
        switch s {
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .unknown:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
        }
    }

    private func refresh() {
        for k in PermissionKind.allCases {
            statuses[k] = PermissionsService.status(k)
        }
    }
}
