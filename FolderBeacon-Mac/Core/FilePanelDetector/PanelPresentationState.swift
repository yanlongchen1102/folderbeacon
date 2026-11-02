/// Presentation is decided once per detected window. Policy changes can hide an
/// automatic presentation but cannot reopen the same dialog.
struct PanelPresentationState {
    enum Presentation { case hidden, automatic, manual }
    private(set) var hasSession = false
    private(set) var presentation: Presentation = .hidden

    mutating func detected(sameWindow: Bool, allowed: Bool) -> Bool {
        guard !sameWindow || !hasSession else { return false }
        hasSession = true
        presentation = allowed ? .automatic : .hidden
        return allowed
    }
    mutating func manualOpen() { presentation = .manual }
    mutating func dismiss() { presentation = .hidden }
    mutating func policyChanged(allowed: Bool) -> Bool {
        guard presentation == .automatic && !allowed else { return false }
        presentation = .hidden
        return true
    }
    mutating func endSession() { hasSession = false; presentation = .hidden }
}
