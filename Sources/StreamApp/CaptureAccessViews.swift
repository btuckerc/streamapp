import SwiftUI

/// One compact row for a single permission; nothing when access is allowed.
struct CaptureAccessNotice: View {
    @ObservedObject var model: StudioModel
    let permission: CapturePermission

    var body: some View {
        let access = model.access(permission)
        if access != .allowed {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(permission.title) access is off")
                switch access {
                case .notDetermined: Button("Allow…") { model.requestAccess(permission) }.buttonStyle(.link)
                case .denied: Button("Open System Settings…") { model.openPrivacySettings(permission) }.buttonStyle(.link)
                case .restricted: Text("Restricted on this Mac").foregroundStyle(.secondary)
                case .allowed: EmptyView()
                }
            }.font(.caption).lineLimit(1)
        }
    }
}

/// One line for the popover summarizing every permission the current setup lacks.
struct CaptureAccessBanner: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        let issues = model.captureAccessIssues
        if let first = issues.first {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(issues.map(\.title).formatted(.list(type: .and))) access needed")
                Spacer(minLength: 0)
                Button("Fix…") { model.requestAccess(first) }.buttonStyle(.link)
            }.font(.caption).lineLimit(1)
        }
    }
}
