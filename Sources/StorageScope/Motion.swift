import AppKit
import SwiftUI

enum MotionTokens {
    static let feedback = 0.12, section = 0.18, navigation = 0.22
    @MainActor static var enabled: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

enum AppTheme {
    static let accent = Color(red: 0.76, green: 0.18, blue: 0.43)
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.10, green: 0.11, blue: 0.14) : Color(red: 0.965, green: 0.970, blue: 0.985)
    }
}

private struct SoftTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let token: String
    let duration: Double
    let back: Bool
    let anchor: UnitPoint
    let zoom: Bool
    @State private var scale = 1.0
    @State private var opacity = 1.0
    @State private var generation = UUID()
    func body(content: Content) -> some View {
        content.scaleEffect(reduceMotion || !zoom ? 1 : scale, anchor: anchor).opacity(reduceMotion ? 1 : opacity)
            .onChange(of: token) { _, _ in
                let next = UUID(); generation = next
                guard !reduceMotion, MotionTokens.enabled else { scale = 1; opacity = 1; return }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { scale = zoom ? (back ? 1.04 : 0.98) : 1; opacity = 0.82 }
                Task { @MainActor in
                    await Task.yield()
                    guard generation == next else { return }
                    withAnimation(.easeOut(duration: duration)) { scale = 1; opacity = 1 }
                }
            }.onChange(of: reduceMotion) { _, value in
                if value { generation = UUID(); scale = 1; opacity = 1 }
            }.onDisappear { generation = UUID() }
    }
}
extension View {
    func softTransition(_ token: String, duration: Double = MotionTokens.section, back: Bool = false, anchor: UnitPoint = .center, zoom: Bool = true) -> some View { modifier(SoftTransition(token: token, duration: duration, back: back, anchor: anchor, zoom: zoom)) }
}

struct SoftButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: MotionTokens.feedback), value: configuration.isPressed)
    }
}
