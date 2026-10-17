import AppKit
import SwiftUI

/// The onboarding's look: near-black, monochrome, hairline-precise. Motion lives in the
/// content, never the background: per-glyph headings, staggered entrances, the notch
/// opening on Welcome and the notch finale.
/// Every continuous effect pauses with Reduce Motion.
enum OnboardingStyle {
    static let accent = SettingsTheme.accent
    static let ink = Color(red: 0.035, green: 0.036, blue: 0.042)
    static let surface = Color(red: 0.075, green: 0.077, blue: 0.086)
    static let raised = Color(red: 0.115, green: 0.118, blue: 0.130)
    static let hairline = Color.white.opacity(0.09)
    /// Brushed metal, for the lit pill and primary actions.
    static let metal = LinearGradient(colors: [Color(white: 0.98), Color(white: 0.80)], startPoint: .top, endPoint: .bottom)
    static let pageSpring = Animation.spring(response: 0.6, dampingFraction: 0.84)
}

private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

private func seconds(_ date: Date) -> Double {
    date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
}

// MARK: - Backdrop

struct OnboardingBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                OnboardingStyle.ink
                // A still overhead light, so the black has depth.
                Ellipse()
                    .fill(RadialGradient(colors: [.white.opacity(0.08), .white.opacity(0.02), .clear],
                                         center: .center, startRadius: 0, endRadius: 320))
                    .frame(width: 760, height: 520)
                    .position(x: proxy.size.width / 2, y: 30)
                // Vignette: the edges fall off to pure black.
                RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center,
                               startRadius: proxy.size.width * 0.35, endRadius: proxy.size.width * 0.85)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Notch

/// A notch body hanging from its top edge: concave ears where it meets the edge and
/// rounded lower corners. The corner radius animates with the size.
struct NotchPanelShape: Shape {
    var ear: CGFloat = 9
    var radius: CGFloat = 14
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let e = min(ear, rect.width / 4, rect.height / 2)
        let r = max(0, min(radius, (rect.width - 2 * e) / 2, rect.height - e))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + e, y: rect.minY + e), control: CGPoint(x: rect.minX + e, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.minX + e, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX - e, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - e, y: rect.minY), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX - e, y: rect.minY + e))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - e, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The finale: the real notch drops down to show the shortcut, holds, and tucks back.
@MainActor
enum NotchHint {
    private static var window: NSWindow?

    /// `retracting` runs as the notch starts to tuck away.
    static func play(keys: [String], retracting: @escaping @MainActor () -> Void) {
        window?.orderOut(nil)
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else {
            return retracting()
        }
        let housing = NotchTrigger.housing(on: screen)
        let notch = CGSize(width: housing?.width ?? 190, height: housing?.height ?? NSStatusBar.system.thickness)
        let expanded = CGSize(width: max(notch.width + 180, 400), height: notch.height + 78)
        let size = CGSize(width: expanded.width + 80, height: expanded.height + 60)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        let state = NotchHintState()
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: NotchHintView(state: state, keys: keys, notch: notch, expanded: expanded))
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        self.window = window

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.spring(response: 0.55, dampingFraction: 0.74)) { state.open = true }
            try? await Task.sleep(for: .seconds(3.0))
            withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { state.open = false }
            retracting()
            try? await Task.sleep(for: .seconds(0.6))
            window.orderOut(nil)
            if Self.window === window { Self.window = nil }
        }
    }
}

@MainActor
private final class NotchHintState: ObservableObject {
    @Published var open = false
}

private struct NotchHintView: View {
    @ObservedObject var state: NotchHintState
    let keys: [String]
    let notch: CGSize
    let expanded: CGSize

    var body: some View {
        let size = state.open ? expanded : notch
        NotchPanelShape(ear: 9, radius: state.open ? 22 : 10)
            .fill(Color.black)
            .overlay(alignment: .top) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Dropy is ready").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        Text("Open it from anywhere").font(.system(size: 11.5)).foregroundStyle(Color(white: 0.55))
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 6) {
                        ForEach(keys.indices, id: \.self) { index in
                            Text(keys[index])
                                .font(.system(size: keys[index].count > 1 ? 12 : 16, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .frame(minWidth: 34, minHeight: 34)
                                .background(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.1)], startPoint: .top, endPoint: .bottom),
                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                                }
                                .scaleEffect(state.open ? 1 : 0.6)
                                .animation(.spring(response: 0.45, dampingFraction: 0.6).delay(state.open ? 0.18 + Double(index) * 0.07 : 0), value: state.open)
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, notch.height + 14)
                .frame(width: expanded.width)
                .opacity(state.open ? 1 : 0)
                .blur(radius: state.open ? 0 : 8)
                .animation(.easeOut(duration: state.open ? 0.35 : 0.15).delay(state.open ? 0.12 : 0), value: state.open)
            }
            .clipShape(NotchPanelShape(ear: 9, radius: state.open ? 22 : 10))
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(state.open ? 0.5 : 0), radius: 20, y: 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Entrances

/// One-shot state for an entrance. An object because the local build does not load
/// SwiftUI's State macro.
@MainActor
final class RevealState: ObservableObject {
    @Published var shown = false
}

/// Rises in from below with a blur, after `order` beats.
struct Rise: ViewModifier {
    let order: Int
    @StateObject private var reveal = RevealState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(reveal.shown ? 1 : 0)
            .offset(y: reveal.shown || reduceMotion ? 0 : 22)
            .scaleEffect(reveal.shown || reduceMotion ? 1 : 0.97)
            .blur(radius: reveal.shown || reduceMotion ? 0 : 10)
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2)
                              : .spring(response: 0.7, dampingFraction: 0.82).delay(0.12 + Double(order) * 0.08)) {
                    reveal.shown = true
                }
            }
    }
}

extension View {
    func rise(_ order: Int) -> some View { modifier(Rise(order: order)) }

    /// A dark machined surface: near-black fill, hairline edge and a lit top edge.
    func onboardingSurface<S: InsettableShape>(_ shape: S) -> some View {
        background(OnboardingStyle.surface, in: shape)
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
    }

    func hoverLift() -> some View { modifier(HoverLift()) }
}

/// Lifts a card toward the pointer while hovered.
private struct HoverLift: ViewModifier {
    @StateObject private var hover = HoverState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(hover.isHovered && !reduceMotion ? 1.02 : 1)
            .offset(y: hover.isHovered && !reduceMotion ? -3 : 0)
            .shadow(color: .black.opacity(hover.isHovered ? 0.6 : 0.35), radius: hover.isHovered ? 22 : 10, y: hover.isHovered ? 12 : 5)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hover.isHovered)
            .onHover { hover.isHovered = $0 }
    }
}

/// Draws a heading one glyph at a time: each rises, sharpens and fades in.
struct GlyphReveal: TextRenderer, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    var displayPadding: EdgeInsets { EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let slices = layout.flatMap { $0 }.flatMap { $0 }
        let count = Double(max(slices.count, 1))
        for (index, slice) in slices.enumerated() {
            let start = Double(index) / count * 0.55
            let local = smoothstep(start, start + 0.45, progress)
            var glyph = context
            glyph.opacity = local
            glyph.translateBy(x: 0, y: (1 - local) * 14)
            if local < 1 { glyph.addFilter(.blur(radius: (1 - local) * 7)) }
            glyph.draw(slice)
        }
    }
}

struct OnboardingHeading: View {
    let title: String
    let detail: String
    @StateObject private var reveal = RevealState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 34, weight: .semibold)).tracking(-1.1)
                .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.62)], startPoint: .top, endPoint: .bottom))
                .textRenderer(GlyphReveal(progress: reveal.shown || reduceMotion ? 1 : 0))
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.system(size: 13.5)).foregroundStyle(Color(white: 0.56))
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 500)
                .rise(3)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).delay(0.08)) { reveal.shown = true }
        }
    }
}

/// The page swap: the new page slides in from the direction of travel and sharpens;
/// the old one blurs and sinks away.
struct PageShift: ViewModifier {
    let x: CGFloat
    let blur: CGFloat
    let scale: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.offset(x: x).blur(radius: blur).scaleEffect(scale).opacity(opacity)
    }
}

extension AnyTransition {
    static func onboardingPage(direction: Int, reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: PageShift(x: CGFloat(direction) * 70, blur: 14, scale: 0.98, opacity: 0),
                                 identity: PageShift(x: 0, blur: 0, scale: 1, opacity: 1)),
            removal: .modifier(active: PageShift(x: 0, blur: 18, scale: 0.94, opacity: 0),
                               identity: PageShift(x: 0, blur: 0, scale: 1, opacity: 1)))
    }
}

// MARK: - Buttons

/// The call to action: a white metal capsule with a light sweep, a hover glow and a
/// springy press.
struct OnboardingPrimaryStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        OnboardingPrimaryBody(configuration: configuration, compact: compact)
    }
}

private struct OnboardingPrimaryBody: View {
    let configuration: ButtonStyleConfiguration
    let compact: Bool
    @StateObject private var hover = HoverState()
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13.5, weight: .semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, compact ? 14 : 22)
            .frame(height: compact ? 28 : 36)
            .background {
                Capsule().fill(OnboardingStyle.metal)
                    .overlay { if !reduceMotion { Shimmer().clipShape(Capsule()) } }
            }
            .shadow(color: .white.opacity(hover.isHovered ? 0.28 : 0.10), radius: hover.isHovered ? 18 : 8)
            .scaleEffect(configuration.isPressed ? 0.94 : hover.isHovered && !reduceMotion ? 1.04 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(response: 0.28, dampingFraction: 0.58), value: configuration.isPressed)
            .animation(.spring(response: 0.35, dampingFraction: 0.65), value: hover.isHovered)
            .contentShape(Capsule())
            .onHover { hover.isHovered = $0 }
            .fixedSize()
    }
}

/// A band of light that crosses the button every few seconds.
private struct Shimmer: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
            GeometryReader { proxy in
                let phase = seconds(timeline.date).truncatingRemainder(dividingBy: 3.6) / 3.6
                let travel = smoothstep(0, 0.4, phase)
                LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 40)
                    .rotationEffect(.degrees(18))
                    .offset(x: -60 + travel * (proxy.size.width + 120))
                    .opacity(0.9)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A quiet dark capsule for secondary actions.
struct OnboardingGlassStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OnboardingGlassBody(configuration: configuration)
    }
}

private struct OnboardingGlassBody: View {
    let configuration: ButtonStyleConfiguration
    @StateObject private var hover = HoverState()

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color(white: hover.isHovered ? 1 : 0.85))
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(hover.isHovered ? OnboardingStyle.raised : OnboardingStyle.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.white.opacity(hover.isHovered ? 0.22 : 0.12), lineWidth: 1) }
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hover.isHovered)
            .contentShape(Capsule())
            .onHover { hover.isHovered = $0 }
            .fixedSize()
    }
}

// MARK: - Heroes

/// A shield on a machined disc; it becomes a green checked shield once both grants are in.
struct ShieldHero: View {
    let allowed: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [(allowed ? Color.green : .white).opacity(0.12), .clear],
                                     center: .center, startRadius: 0, endRadius: 70))
                .frame(width: 140, height: 140)
            Circle().fill(OnboardingStyle.surface).frame(width: 84, height: 84)
                .overlay { Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)) }
            Image(systemName: allowed ? "checkmark.shield.fill" : "lock.shield.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(allowed ? AnyShapeStyle(Color.green) : AnyShapeStyle(OnboardingStyle.metal))
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(height: 110)
        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: allowed)
        .accessibilityHidden(true)
    }
}

/// The shortcut as real keycaps that press themselves in order, then send a ripple
/// out as if Dropy had opened.
struct KeycapHero: View {
    let keys: [String]
    let isRecording: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion || isRecording)) { timeline in
            let cycle = seconds(timeline.date).truncatingRemainder(dividingBy: 3.4)
            let chord = 0.25 + Double(max(keys.count - 1, 0)) * 0.22 + 0.1
            ZStack {
                let ripple = smoothstep(chord, chord + 1.0, cycle)
                Capsule()
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                    .frame(width: 80 + Double(keys.count) * 76, height: 96)
                    .scaleEffect(1 + ripple * 0.35)
                    .opacity(reduceMotion || isRecording || cycle < chord ? 0 : (1 - ripple) * 0.8)
                HStack(spacing: 12) {
                    if isRecording {
                        RecordingPrompt()
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        ForEach(keys.indices, id: \.self) { index in
                            let start = 0.25 + Double(index) * 0.22
                            let depth = reduceMotion ? 0 : smoothstep(start, start + 0.09, cycle) * (1 - smoothstep(2.1, 2.25, cycle))
                            Keycap(label: keys[index], depth: depth)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                }
            }
        }
        .frame(height: 130)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: isRecording)
    }
}

private struct Keycap: View {
    let label: String
    let depth: Double

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.black)
                .overlay { RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1) }
                .offset(y: 7)
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.28 + depth * 0.4), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                                      lineWidth: 1)
                }
                .overlay {
                    Text(label)
                        .font(.system(size: label.count > 1 ? 17 : 28, weight: .regular))
                        .foregroundStyle(Color(white: 0.75 + depth * 0.25))
                        .padding(.horizontal, 18)
                }
                .offset(y: depth * 6)
                .shadow(color: .white.opacity(depth * 0.22), radius: 18 * depth)
        }
        .frame(minWidth: 68)
        .frame(height: 74)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct RecordingPrompt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { timeline in
            let t = seconds(timeline.date)
            HStack(spacing: 10) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                    .opacity(0.5 + 0.5 * sin(t * 5))
                Text("Press keys…").font(.system(size: 20, weight: .medium))
            }
            .padding(.horizontal, 26).frame(height: 68)
            .overlay {
                Capsule()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 5], dashPhase: t * 18))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .scaleEffect(1 + 0.02 * sin(t * 3))
        }
    }
}
