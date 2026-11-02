import Foundation

@main
struct PanelPresentationStateTests {
    static func main() {
        var state = PanelPresentationState()
        precondition(state.detected(sameWindow: false, allowed: true))
        precondition(state.presentation == .automatic)
        state.dismiss()
        precondition(!state.detected(sameWindow: true, allowed: true) && state.presentation == .hidden)
        state.endSession()
        precondition(!state.detected(sameWindow: false, allowed: false))
        // Removing an exception or enabling the global switch cannot reopen this window.
        precondition(!state.detected(sameWindow: true, allowed: true) && state.presentation == .hidden)
        state.manualOpen()
        precondition(state.presentation == .manual)
        precondition(!state.policyChanged(allowed: false) && state.presentation == .manual)
        state.endSession()
        precondition(state.detected(sameWindow: false, allowed: true))
        state.manualOpen() // Shortcut takes ownership of an automatic presentation.
        precondition(!state.policyChanged(allowed: false) && state.presentation == .manual)
        state.dismiss()
        precondition(!state.detected(sameWindow: true, allowed: true))
        state.endSession()
        precondition(state.detected(sameWindow: false, allowed: true))
        precondition(state.policyChanged(allowed: false) && state.presentation == .hidden)
        precondition(!state.detected(sameWindow: true, allowed: true))
        state.endSession()
        precondition(state.detected(sameWindow: false, allowed: true))
        print("PASS: session decisions, dismissals, manual opening, takeover, and policy changes")
    }
}
