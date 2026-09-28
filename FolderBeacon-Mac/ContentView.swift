import SwiftUI

enum SettingsPage: Hashable {
    case gettingStarted, general, shortcut, favorites, searchScopes, permissions, about
    var title: String { switch self { case .gettingStarted: L10n.string("Getting Started"); case .general: L10n.string("General"); case .shortcut: L10n.string("Shortcut"); case .favorites: L10n.string("Favorites"); case .searchScopes: L10n.string("Search Folders"); case .permissions: L10n.string("Permissions"); case .about: L10n.string("About") } }
    var icon: String { switch self { case .gettingStarted: "sparkles"; case .general: "gearshape"; case .shortcut: "command"; case .favorites: "star"; case .searchScopes: "folder.badge.gearshape"; case .permissions: "checkmark.shield"; case .about: "info.circle" } }
}

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var language = AppLanguage.shared
    @State private var selection: SettingsPage

    init(state: AppState, initialPage: SettingsPage = .gettingStarted) {
        self.state = state
        _selection = State(initialValue: initialPage)
    }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                Section { pageLink(.gettingStarted) }
                Section(L10n.string("Settings")) { pageLink(.general); pageLink(.shortcut); pageLink(.favorites); pageLink(.searchScopes); pageLink(.permissions) }
                Section { pageLink(.about) }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)

            Group {
                switch selection {
                case .gettingStarted: GettingStartedView(state: state)
                case .general: GeneralView(state: state)
                case .shortcut: ShortcutView(state: state)
                case .favorites: FavoritesView(state: state)
                case .searchScopes: SearchScopeSettingsView(state: state)
                case .permissions: PermissionsView(state: state)
                case .about: AboutView()
                }
            }
            .frame(minWidth: 560, minHeight: 520)
            .id(language.localization)
        }
        .onReceive(state.$requestedSettingsPage) { page in if let page { selection = page; state.requestedSettingsPage = nil } }
    }
    private func pageLink(_ page: SettingsPage) -> some View { Label(page.title, systemImage: page.icon).tag(page) }
}

private struct GettingStartedView: View {
    @ObservedObject var state: AppState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Image("BrandMark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                    .padding(.bottom, 12)
                Text(L10n.string("Stop digging through folders every time you open or save a file.")).font(.system(size: 30, weight: .bold))
                Text(L10n.string("FolderBeacon appears automatically in Open and Save dialogs. Quickly search for and jump to the folder you need.")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                Image(systemName: "rectangle.and.text.magnifyingglass").font(.title).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("How it works")).font(.headline)
                    Text(L10n.string("No extra steps needed.")).fontWeight(.medium)
                    Text(L10n.string("When an Open or Save dialog appears, FolderBeacon shows up automatically. Choose a folder, and the current dialog jumps there instantly.")).foregroundStyle(.secondary)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 0) {
                FeatureRow(icon: "sparkles", title: "Auto Show", detail: "Automatically appears when an Open or Save dialog is detected.")
                Divider()
                FeatureRow(icon: "magnifyingglass", title: "Find folders faster", detail: "Search favorites, recent locations, and folders currently open in Finder.")
                Divider()
                FeatureRow(icon: "arrow.right", title: "Jump instantly", detail: "Select a folder and the current Open or Save dialog navigates there immediately.")
                }
            } label: {
                Text(L10n.string("Features")).font(.headline)
            }
            .padding(14)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            PermissionGuidanceView(state: state)

            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string(title)).fontWeight(.medium)
                Text(L10n.string(detail)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }
}

private struct GeneralView: View {
    @AppStorage("PathPilot.showFinderWindows") private var showFinderWindows = true
    @AppStorage("PathPilot.showRecentFolders") private var showRecentFolders = true
    var state: AppState
    @ObservedObject private var language = AppLanguage.shared
    var body: some View { Form { Section(L10n.string("Language")) { Picker(L10n.string("App Language"), selection: $language.choice) { ForEach(AppLanguage.Choice.allCases) { choice in Text(choice.title).tag(choice) } }; Text(L10n.string("Choose the language used by FolderBeacon.")).font(.caption).foregroundStyle(.secondary) }; Section(L10n.string("Behavior")) { Toggle(L10n.string("Show Finder Windows"), isOn: $showFinderWindows); Toggle(L10n.string("Show Recent Folders"), isOn: $showRecentFolders) }; Section(L10n.string("Support")) { LabeledContent(L10n.string("Accessibility"), value: L10n.string(state.isAccessibilityTrusted ? "Enabled" : "Needs Setup")); Button(L10n.string("Open Permissions")) { state.openSettings(.permissions) } } }.formStyle(.grouped) }
}

private struct ShortcutView: View {
    @ObservedObject var state: AppState
    @State private var isRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("Open Panel")).font(.headline)
            Text(state.globalShortcut.displayText)
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .padding(.horizontal, 24).padding(.vertical, 14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            if isRecording {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.16))
                    Text(L10n.string("Press your new shortcut…"))
                    ShortcutRecorder { shortcut in
                        state.updateGlobalShortcut(shortcut)
                        isRecording = false
                    }
                }
                .frame(width: 300, height: 36)
            } else {
                HStack {
                    Button(L10n.string("Record Shortcut")) { isRecording = true }
                    Button(L10n.string("Reset to Default")) { state.updateGlobalShortcut(.default) }
                }
            }

            Text(L10n.string("Use at least one modifier key. FolderBeacon checks whether macOS can register the shortcut; if it is already in use, your previous shortcut remains active."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !state.globalShortcutStatus.isEmpty {
                Text(state.globalShortcutStatus).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(32)
    }
}

private struct FavoritesView: View {
    @ObservedObject var state: AppState
    var body: some View { VStack(alignment: .leading, spacing: 14) { if state.projectStore.folders.isEmpty { ContentUnavailableView(L10n.string("No Favorites"), systemImage: "star", description: Text(L10n.string("Add folders you visit often for instant access in the panel."))) } else { List { ForEach(state.projectStore.folders) { folder in HStack { Image(systemName: "folder.fill").foregroundStyle(.yellow); VStack(alignment: .leading) { TextField(L10n.string("Name"), text: Binding(get: { folder.name }, set: { state.projectStore.rename(id: folder.id, to: $0) })); Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }; Button(role: .destructive) { state.projectStore.remove(id: folder.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) } }.onMove(perform: state.projectStore.move) }.listStyle(.inset) }; Button { state.chooseFavoriteFolder() } label: { Label(L10n.string("Add Folder"), systemImage: "plus") } }.padding() }
}

private struct PermissionGuidanceView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Permissions")).font(.title2.bold())
            permissionCard(
                title: "Navigate File Dialogs",
                detail: "Allows FolderBeacon to jump between folders inside standard or Accessibility-compatible macOS Open and Save dialogs.",
                enabled: state.isAccessibilityTrusted
            ) {
                Button(L10n.string("Open System Settings")) {
                    if state.isAccessibilityTrusted {
                        AccessibilityPermissionManager.openSettings()
                    } else {
                        state.requestAccessibilityPermission()
                    }
                }
            }
            permissionCard(
                title: "Finder Access",
                detail: "Allows FolderBeacon to show directories from open Finder windows.",
                enabled: state.isFinderAccessAvailable
            ) {
                HStack {
                    Button(L10n.string("Check Finder Access")) { state.testFinderAutomationPermission() }
                    Button(L10n.string("Open System Settings")) {
                        AccessibilityPermissionManager.openSettings(pane: "Privacy_Automation")
                    }
                }
            }
        }
    }

    private func permissionCard<Actions: View>(title: String, detail: String, enabled: Bool, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.string(title)).font(.headline)
                Spacer()
                Label(L10n.string(enabled ? "Enabled" : "Needs Setup"), systemImage: enabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(enabled ? Color.green : Color.red)
            }
            Text(L10n.string(detail)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(enabled ? Color.secondary.opacity(0.08) : Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(enabled ? Color.clear : Color.red.opacity(0.45)))
    }
}

private struct PermissionsView: View {
    @ObservedObject var state: AppState
    var body: some View {
        ScrollView {
            PermissionGuidanceView(state: state).padding(24)
        }
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image("BrandMark")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 88, height: 88)
                .padding(.top, 24)
            Text("FolderBeacon").font(.title.bold())
            Text(L10n.string("A context-aware folder navigation tool for macOS."))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}
