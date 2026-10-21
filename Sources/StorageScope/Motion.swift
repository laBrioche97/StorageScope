import AppKit
import SwiftUI

enum MotionTokens {
    static let feedback = 0.12, section = 0.18, navigation = 0.22
    @MainActor static var enabled: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

private struct SoftTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let token: String
    let duration: Double
    let back: Bool
    let anchor: UnitPoint
    @State private var scale = 1.0
    @State private var opacity = 1.0
    @State private var generation = UUID()
    func body(content: Content) -> some View {
        content.scaleEffect(reduceMotion ? 1 : scale, anchor: anchor).opacity(reduceMotion ? 1 : opacity)
            .onChange(of: token) { _, _ in
                let next = UUID(); generation = next
                guard !reduceMotion, MotionTokens.enabled else { scale = 1; opacity = 1; return }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { scale = back ? 1.04 : .98; opacity = .82 }
                Task { @MainActor in
                    await Task.yield()
                    guard generation == next else { return }
                    withAnimation(.easeOut(duration: duration)) { scale = 1; opacity = 1 }
                }
            }.onDisappear { generation = UUID() }
    }
}
extension View {
    func softTransition(_ token: String, duration: Double = MotionTokens.section, back: Bool = false, anchor: UnitPoint = .center) -> some View { modifier(SoftTransition(token: token, duration: duration, back: back, anchor: anchor)) }
}

struct SoftButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? .75 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: MotionTokens.feedback), value: configuration.isPressed)
    }
}
