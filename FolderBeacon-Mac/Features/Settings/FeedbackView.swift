import SwiftUI

private enum FeedbackKind: String, CaseIterable, Identifiable {
    case incompatibleApp
    case suggestion
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .incompatibleApp: L10n.string("Incompatible App")
        case .suggestion: L10n.string("Suggestion")
        case .other: L10n.string("Other")
        }
    }
}

struct FeedbackView: View {
    @State private var kind: FeedbackKind = .incompatibleApp
    @State private var appName = ""
    @State private var message = ""
    @State private var didSubmit = false

    private var canSubmit: Bool {
        let hasAppName = kind != .incompatibleApp || !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasAppName && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("Help improve FolderBeacon"))
                        .font(.title2.bold())
                    Text(L10n.string("Tell us which apps do not work with FolderBeacon, or share an idea for making it better."))
                        .foregroundStyle(.secondary)
                }

                feedbackCard(title: L10n.string("Feedback Type")) {
                        Picker(L10n.string("Feedback Type"), selection: $kind) {
                            ForEach(FeedbackKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                }

                if kind == .incompatibleApp {
                    feedbackCard(title: L10n.string("App Details")) {
                            TextField(L10n.string("App name (required)"), text: $appName)
                                .textFieldStyle(.roundedBorder)
                            Text(L10n.string("For example: Preview, Figma, or an app from the Mac App Store."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                    }
                }

                feedbackCard(title: L10n.string("Your Feedback")) {
                        TextEditor(text: $message)
                            .font(.body)
                            .frame(minHeight: 150)
                            .overlay(alignment: .topLeading) {
                                if message.isEmpty {
                                    Text(L10n.string("What happened, or what would you like to see?"))
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8)
                                        .padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                    }

                Text(L10n.string("When you submit, your feedback, the app name you provide, FolderBeacon version, and macOS version are sent to help us improve. Please do not include personal or sensitive information."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button(L10n.string("Send Feedback")) { submit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmit || didSubmit)
                    if didSubmit {
                        Label(L10n.string("Thanks for your feedback!"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .onAppear { UsageAnalytics.capture(.feedbackOpened) }
    }

    private func submit() {
        UsageAnalytics.captureFeedback(
            kind: kind.rawValue,
            incompatibleApp: kind == .incompatibleApp ? appName : nil,
            message: message
        )
        didSubmit = true
    }

    private func feedbackCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
