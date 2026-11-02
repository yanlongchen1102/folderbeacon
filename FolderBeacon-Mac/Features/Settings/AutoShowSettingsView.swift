import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AutoShowSettingsView: View {
    @ObservedObject var policy: AutoShowPolicy
    @State private var showingPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(L10n.string("Show automatically in Open and Save dialogs"), isOn: $policy.enabled)
            Text(L10n.string(policy.enabled ? "FolderBeacon appears automatically in compatible dialogs, except for the apps below." : "Automatic display is off. Your exceptions are saved, and the shortcut still works."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.string("App Exceptions")).font(.headline)
            if policy.exceptions.isEmpty {
                ContentUnavailableView(L10n.string("No App Exceptions"), systemImage: "app.badge.checkmark", description: Text(L10n.string("Add apps where FolderBeacon should not appear automatically.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(policy.exceptions) { app in
                    HStack {
                        if let path = app.path { Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 32, height: 32) }
                        else { Image(systemName: "app").frame(width: 32, height: 32) }
                        VStack(alignment: .leading) {
                            Text(app.name)
                            Text(app.path ?? app.bundleIdentifier).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(L10n.string("Remove")) { policy.remove(app.id) }
                    }.padding(.vertical, 3)
                }
            }
            Text(L10n.string("Removing an exception takes effect for the next dialog."))
                .font(.caption).foregroundStyle(.secondary)
            Button { showingPicker = true } label: { Label(L10n.string("Add Apps…"), systemImage: "plus") }
        }
        .padding(24)
        .sheet(isPresented: $showingPicker) { AppExceptionPicker(policy: policy) }
    }
}

private struct AppExceptionPicker: View {
    @ObservedObject var policy: AutoShowPolicy
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection = Set<String>()
    private var allApps: [AppException] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(AppException.init(application:))
            .filter { app in seen.insert(app.id).inserted && !policy.exceptions.contains(where: { $0.id == app.id }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var apps: [AppException] { allApps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleIdentifier.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Add App Exceptions")).font(.headline)
            Text(L10n.string("Choose running apps or browse for an app.")).foregroundStyle(.secondary)
            TextField(L10n.string("Search apps"), text: $search)
            List(apps, selection: $selection) { app in
                HStack {
                    if let path = app.path { Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 24, height: 24) }
                    Text(app.name)
                    Spacer()
                    Text(app.bundleIdentifier).foregroundStyle(.secondary).font(.caption)
                }.tag(app.id)
            }
            HStack {
                Button(L10n.string("Browse Apps…")) { browse() }
                Spacer()
                Button(L10n.string("Cancel")) { dismiss() }
                Button(L10n.string("Add Selected")) {
                    allApps.filter { selection.contains($0.id) }.forEach { policy.add($0) }
                    dismiss()
                }.disabled(selection.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 520, height: 440)
    }
    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK { panel.urls.compactMap(AppException.init(url:)).forEach { policy.add($0) } }
    }
}
