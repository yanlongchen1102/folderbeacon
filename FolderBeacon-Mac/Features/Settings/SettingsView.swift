import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    let initialPage: SettingsPage

    init(state: AppState, initialPage: SettingsPage = .gettingStarted) {
        self.state = state
        self.initialPage = initialPage
    }

    var body: some View { ContentView(state: state, initialPage: initialPage) }
}
