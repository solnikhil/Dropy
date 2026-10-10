import AppKit
import SwiftUI
import DropyCore

enum StudioColors {
    static let width = SettingsTheme.accent
    static let height = SettingsTheme.badge
    static func color(_ channel: AnimationStudioModel.Channel) -> Color { channel == .width ? width : height }
}

// MARK: Geometry

/// What the graph shows: seconds across, progress up.
struct GraphDomain: Equatable {
    var duration: Double
    var low: Double
    var high: Double

    static func fitting(_ motion: NotchMorph.Motion?, extra: Double = 0) -> GraphDomain {
        guard let motion else { return GraphDomain(duration: 0.6, low: -0.15, high: 1.25) }
        let end = max(motion.duration, extra, 0.3) * 1.2
        let width = motion.width.extent
        let height = motion.height.extent
        return GraphDomain(duration: (end * 10).rounded(.up) / 10,
                           low: min(-0.15, min(width.lowerBound, height.lowerBound) - 0.08),
                           high: max(1.25, max(width.upperBound, height.upperBound) + 0.08))
    }
}

struct GraphGeometry {
    let size: CGSize
    let domain: GraphDomain
    static let leading: CGFloat = 44
    static let trailing: CGFloat = 16
    static let top: CGFloat = 16
    static let bottom: CGFloat = 26

    var plot: CGRect {
        CGRect(x: Self.leading, y: Self.top, width: max(10, size.width - Self.leading - Self.trailing),
               height: max(10, size.height - Self.top - Self.bottom))
    }

    func point(_ time: Double, _ value: Double) -> CGPoint {
        let plot = plot
        return CGPoint(x: plot.minX + plot.width * CGFloat(time / domain.duration),
                       y: plot.maxY - plot.height * CGFloat((value - domain.low) / (domain.high - domain.low)))
    }

    func time(at x: CGFloat) -> Double { Double((x - plot.minX) / plot.width) * domain.duration }
    func value(at y: CGFloat) -> Double { domain.low + Double((plot.maxY - y) / plot.height) * (domain.high - domain.low) }
}

/// Where a spring's one handle sits: its first peak (or, without a bounce, where it is
/// nearly there). Dragging it sideways sets the speed and up or down the bounce.
enum SpringHandle {
    /// Time a critically damped spring takes to reach 98 %, in responses.
    static let settleFactor = 0.928

    static func point(_ spring: MorphSpring, delay: Double) -> (time: Double, value: Double) {
        let zeta = spring.dampingRatio
        guard zeta < 0.999 else { return (delay + settleFactor * spring.response, 1) }
        let root = (1 - zeta * zeta).squareRoot()
        return (delay + spring.response / (2 * root), 1 + exp(-Double.pi * zeta / root))
    }

    static func spring(at time: Double, value: Double, delay: Double) -> MorphSpring {
        let lowest = AnimationLimits.damping.lowerBound
        let most = exp(-Double.pi * lowest / (1 - lowest * lowest).squareRoot())
        let overshoot = min(max(value - 1, 0), most)
        let span = max(time - delay, 0.02)
        let zeta: Double
        let response: Double
        if overshoot < 0.003 {
            zeta = 1
            response = span / settleFactor
        } else {
            let log = Foundation.log(overshoot)
            zeta = -log / (Double.pi * Double.pi + log * log).squareRoot()
            response = 2 * span * (1 - zeta * zeta).squareRoot()
        }
        // Tidy numbers in the file: milliseconds and hundredths.
        let tidyResponse = (min(max(response, AnimationLimits.response.lowerBound), AnimationLimits.response.upperBound) * 1000).rounded() / 1000
        let tidyDamping = (min(max(zeta, AnimationLimits.damping.lowerBound), AnimationLimits.damping.upperBound) * 100).rounded() / 100
        return MorphSpring(response: tidyResponse, dampingRatio: tidyDamping)
    }
}

// MARK: Graph

/// Drag state for the graph, kept outside the view (the local build has no State macro).
@MainActor
final class GraphInteraction: ObservableObject {
    enum Target: Equatable { case key(Int), springPeak, springDelay, stroke, nothing }
    @Published var target: Target?
    @Published var stroke: [CGPoint] = []
    @Published var frozen: GraphDomain?
    @Published var hover: CGPoint?
    var lastClick: (time: Date, location: CGPoint)?
}

/// The selected motion as curves over time: width and height, with keyframes to drag,
/// a spring handle, a pen to draw a curve, and a playhead while the stage plays.
struct MotionGraph: View {
    @ObservedObject var model: AnimationStudioModel
    @StateObject private var interaction = GraphInteraction()

    var body: some View {
        GeometryReader { proxy in
            let domain = interaction.frozen ?? GraphDomain.fitting(model.motion)
            let geometry = GraphGeometry(size: proxy.size, domain: domain)
            ZStack(alignment: .topTrailing) {
                Canvas { context, _ in draw(in: &context, geometry: geometry) }
                TimelineView(.animation(minimumInterval: nil, paused: model.playing == nil)) { _ in
                    Canvas { context, _ in drawPlayhead(in: &context, geometry: geometry) }
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) { legend.padding(.leading, GraphGeometry.leading + 8).padding(.top, 22) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragChanged($0, geometry: geometry) }
                .onEnded { dragEnded($0, geometry: geometry) })
            .onContinuousHover { phase in
                if case .active(let location) = phase { interaction.hover = location } else { interaction.hover = nil }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onDeleteCommand { if let key = model.selectedKey { model.deleteKey(key) } }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .tab], phases: [.down, .repeat]) { press in
            nudge(press.key, large: press.modifiers.contains(.shift)) ? .handled : .ignored
        }
        .accessibilityElement()
        .accessibilityLabel("\(model.tab.title) curves")
        .accessibilityValue(model.motion.map { motion in
            let curve = model.channel == .width ? motion.width : motion.height
            let kind = model.keys.map { "\($0.count) keyframes" } ?? "spring"
            return String(format: "%@, %@, done after %.2f seconds", model.channel.title, kind, curve.duration)
        } ?? "")
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Which part's curve is being edited; click to switch.
    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(AnimationStudioModel.Channel.allCases) { channel in
                Button { model.channel = channel } label: {
                    HStack(spacing: 5) {
                        Circle().fill(StudioColors.color(channel)).frame(width: 8, height: 8)
                        Text(channel.title)
                            .font(model.channel == channel ? SettingsMetrics.bodyEmphasis : SettingsMetrics.body)
                            .foregroundStyle(model.channel == channel ? .primary : .secondary)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(model.channel == channel ? SettingsTheme.control : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(channel.detail)
            }
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, geometry: GraphGeometry) {
        let plot = geometry.plot
        let domain = geometry.domain
        // Bands: past the end, and back past the start.
        let one = geometry.point(0, 1).y
        let zero = geometry.point(0, 0).y
        context.fill(Path(CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: max(0, one - plot.minY))),
                     with: .color(StudioColors.width.opacity(0.06)))
        context.fill(Path(CGRect(x: plot.minX, y: zero, width: plot.width, height: max(0, plot.maxY - zero))),
                     with: .color(StudioColors.height.opacity(0.05)))
        label("overshoot", at: CGPoint(x: plot.maxX - 6, y: max(plot.minY + 8, one - 8)), in: &context, anchor: .trailing, opacity: 0.45)
        // Progress lines.
        for (value, name, strength) in [(0.0, "start", 0.22), (1.0, "end", 0.22), (0.5, "50 %", 0.08)] {
            var line = Path()
            line.move(to: geometry.point(0, value))
            line.addLine(to: geometry.point(domain.duration, value))
            context.stroke(line, with: .color(.primary.opacity(strength)), lineWidth: 1)
            label(name, at: CGPoint(x: plot.minX - 6, y: geometry.point(0, value).y), in: &context, anchor: .trailing)
        }
        // Seconds.
        let step = plot.width / CGFloat(domain.duration / 0.1) > 46 ? 0.1 : 0.2
        var time = step
        while time < domain.duration - 0.001 {
            var line = Path()
            line.move(to: CGPoint(x: geometry.point(time, 0).x, y: plot.minY))
            line.addLine(to: CGPoint(x: geometry.point(time, 0).x, y: plot.maxY))
            context.stroke(line, with: .color(.primary.opacity(0.06)), lineWidth: 1)
            label(String(format: "%.1f s", time), at: CGPoint(x: geometry.point(time, 0).x, y: plot.maxY + 12), in: &context)
            time += step
        }
        guard let motion = model.motion else { return }
        // Where the motion is done.
        let end = geometry.point(motion.duration, 0).x
        var done = Path()
        done.move(to: CGPoint(x: end, y: plot.minY))
        done.addLine(to: CGPoint(x: end, y: plot.maxY))
        context.stroke(done, with: .color(.primary.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        label(String(format: "done %.2f s", motion.duration), at: CGPoint(x: end + 4, y: plot.minY + 8), in: &context,
              anchor: .leading, opacity: 0.7)

        let selected = model.channel
        if let reference = model.reference, let part = model.part {
            let other = reference.animation[part]
            let curve = selected == .width ? other.width : other.height
            let shown = PlayedProgress.played(other)
            let ghost = path(geometry: geometry) { other.isMonotonic ? shown($0)[selected == .width ? 0 : 1] : curve.value(at: $0) }
            context.stroke(ghost, with: .color(.primary.opacity(0.28)), style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
            let end = geometry.point(min(other.duration, geometry.domain.duration), 1)
            label(reference.title, at: CGPoint(x: end.x, y: end.y + 12), in: &context, opacity: 0.45)
        }
        let played = PlayedProgress.played(motion)
        for channel in [selected == .width ? AnimationStudioModel.Channel.height : .width, selected] {
            let isSelected = channel == selected
            let curve = channel == .width ? motion.width : motion.height
            let color = StudioColors.color(channel)
            if motion.isMonotonic {
                // As written, faint and dashed, when closing forward-only changes it.
                let raw = path(geometry: geometry) { curve.value(at: $0) }
                context.stroke(raw, with: .color(color.opacity(isSelected ? 0.35 : 0.15)),
                               style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
            }
            let shown = path(geometry: geometry) { played($0)[channel == .width ? 0 : 1] }
            context.stroke(shown, with: .color(color.opacity(isSelected ? 1 : 0.32)),
                           style: StrokeStyle(lineWidth: isSelected ? 2.6 : 1.6, lineCap: .round, lineJoin: .round))
        }
        if model.tool == .select { drawHandles(in: &context, geometry: geometry) }
        if !interaction.stroke.isEmpty {
            var stroke = Path()
            stroke.addLines(interaction.stroke)
            context.stroke(stroke, with: .color(StudioColors.color(selected)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawHandles(in context: inout GraphicsContext, geometry: GraphGeometry) {
        let color = StudioColors.color(model.channel)
        if let keys = model.keys {
            for (index, key) in keys.enumerated() {
                let center = geometry.point(key.time, key.value)
                let selected = model.selectedKey == index
                let radius: CGFloat = selected ? 6.5 : 5
                let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.fill(circle, with: .color(selected ? .white : color))
                context.stroke(circle, with: .color(selected ? color : .black.opacity(0.35)), lineWidth: selected ? 2.5 : 1)
                if selected {
                    label(String(format: "%.2f s · %.0f %%", key.time, key.value * 100),
                          at: CGPoint(x: center.x, y: center.y - 16), in: &context, opacity: 1)
                }
            }
        } else if let spring = model.spring {
            let handle = SpringHandle.point(spring.spring, delay: spring.delay)
            let center = geometry.point(handle.time, handle.value)
            let active = interaction.target == .springPeak
            let ring = Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16))
            context.fill(ring, with: .color(active ? .white : color))
            context.stroke(ring, with: .color(active ? color : .white.opacity(0.85)), lineWidth: 2.5)
            label(String(format: "%.2f s · bounce %.0f %%", spring.spring.response, (1 - spring.spring.dampingRatio) * 100),
                  at: CGPoint(x: center.x, y: center.y - 18), in: &context, opacity: 0.9)
            let start = geometry.point(spring.delay, 0)
            let square = Path(roundedRect: CGRect(x: start.x - 5, y: start.y - 5, width: 10, height: 10), cornerRadius: 2)
            context.fill(square, with: .color(color.opacity(interaction.target == .springDelay ? 1 : 0.75)))
            if spring.delay > 0 {
                label(String(format: "waits %.2f s", spring.delay), at: CGPoint(x: start.x + 8, y: start.y + 14), in: &context,
                      anchor: .leading)
            }
        }
    }

    private func drawPlayhead(in context: inout GraphicsContext, geometry: GraphGeometry) {
        guard let playing = model.playing, playing.part == model.part else { return }
        let elapsed = (CACurrentMediaTime() - playing.start) / playing.slowdown
        guard elapsed >= 0, elapsed <= geometry.domain.duration else { return }
        let x = geometry.point(elapsed, 0).x
        var line = Path()
        line.move(to: CGPoint(x: x, y: geometry.plot.minY))
        line.addLine(to: CGPoint(x: x, y: geometry.plot.maxY))
        context.stroke(line, with: .color(.primary.opacity(0.7)), lineWidth: 1.5)
    }

    private func path(geometry: GraphGeometry, _ value: (Double) -> Double) -> Path {
        var path = Path()
        let steps = 240
        for step in 0...steps {
            let time = geometry.domain.duration * Double(step) / Double(steps)
            let point = geometry.point(time, value(time))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private func label(_ text: String, at point: CGPoint, in context: inout GraphicsContext,
                       anchor: UnitPoint = .center, opacity: Double = 0.6) {
        context.draw(Text(text).font(.system(size: 10).monospacedDigit()).foregroundColor(.primary.opacity(opacity)),
                     at: point, anchor: anchor)
    }

    // MARK: Keyboard

    /// Arrow keys move the selected keyframe (5 ms or 1 % a press, five times that with
    /// Shift) or, on a spring, its speed and bounce; Tab moves to the next keyframe.
    private func nudge(_ key: KeyEquivalent, large: Bool) -> Bool {
        let scale = large ? 5.0 : 1.0
        if let keys = model.keys {
            if key == .tab {
                model.selectedKey = ((model.selectedKey ?? -1) + 1) % keys.count
                return true
            }
            guard let index = model.selectedKey, keys.indices.contains(index) else { return false }
            let current = keys[index]
            switch key {
            case .leftArrow: model.moveKey(index, time: current.time - 0.005 * scale)
            case .rightArrow: model.moveKey(index, time: current.time + 0.005 * scale)
            case .upArrow: model.moveKey(index, value: current.value + 0.01 * scale)
            case .downArrow: model.moveKey(index, value: current.value - 0.01 * scale)
            default: return false
            }
            return true
        }
        guard let spring = model.spring else { return false }
        switch key {
        case .leftArrow: model.updateSpring(response: max(AnimationLimits.response.lowerBound, spring.spring.response - 0.01 * scale))
        case .rightArrow: model.updateSpring(response: min(AnimationLimits.response.upperBound, spring.spring.response + 0.01 * scale))
        case .upArrow: model.updateSpring(damping: max(AnimationLimits.damping.lowerBound, spring.spring.dampingRatio - 0.01 * scale))
        case .downArrow: model.updateSpring(damping: min(AnimationLimits.damping.upperBound, spring.spring.dampingRatio + 0.01 * scale))
        default: return false
        }
        return true
    }

    // MARK: Dragging

    private func dragChanged(_ drag: DragGesture.Value, geometry: GraphGeometry) {
        if interaction.target == nil { begin(at: drag.startLocation, geometry: geometry) }
        let time = geometry.time(at: drag.location.x)
        var value = geometry.value(at: drag.location.y)
        // A gentle pull towards the end and the start lines.
        for line in [0.0, 1.0] where abs(value - line) < 0.025 { value = line }
        switch interaction.target {
        case .key(let index):
            model.moveKey(index, time: time, value: value)
        case .springPeak:
            guard let spring = model.spring else { return }
            let next = SpringHandle.spring(at: time, value: value, delay: spring.delay)
            model.updateSpring(response: next.response, damping: next.dampingRatio)
        case .springDelay:
            let delay = (min(max(time, AnimationLimits.delay.lowerBound), AnimationLimits.delay.upperBound) * 100).rounded() / 100
            model.updateSpring(delay: delay)
        case .stroke:
            if let last = interaction.stroke.last, drag.location.x <= last.x { return }
            interaction.stroke.append(drag.location)
        case .nothing, nil:
            break
        }
    }

    private func begin(at location: CGPoint, geometry: GraphGeometry) {
        interaction.frozen = geometry.domain
        if model.tool == .draw {
            interaction.target = .stroke
            interaction.stroke = [location]
            return
        }
        if let keys = model.keys {
            let hit = keys.indices.min { distance(geometry.point(keys[$0].time, keys[$0].value), location)
                < distance(geometry.point(keys[$1].time, keys[$1].value), location) }
            if let hit, distance(geometry.point(keys[hit].time, keys[hit].value), location) < 11 {
                model.selectedKey = hit
                model.beginGesture()
                interaction.target = .key(hit)
                return
            }
        } else if let spring = model.spring {
            let peak = SpringHandle.point(spring.spring, delay: spring.delay)
            if distance(geometry.point(peak.time, peak.value), location) < 13 {
                model.beginGesture()
                interaction.target = .springPeak
                return
            }
            if distance(geometry.point(spring.delay, 0), location) < 10 {
                model.beginGesture()
                interaction.target = .springDelay
                return
            }
        }
        interaction.target = .nothing
    }

    private func dragEnded(_ drag: DragGesture.Value, geometry: GraphGeometry) {
        defer {
            interaction.target = nil
            interaction.frozen = nil
        }
        switch interaction.target {
        case .key, .springPeak, .springDelay:
            model.endGesture()
        case .stroke:
            let points = interaction.stroke.map { (time: geometry.time(at: $0.x), value: geometry.value(at: $0.y)) }
            interaction.stroke = []
            model.applyStroke(points)
        case .nothing, nil:
            // A click: a second one close by soon after adds a keyframe there.
            let moved = distance(drag.startLocation, drag.location)
            guard moved < 4 else { return }
            let now = Date()
            if let last = interaction.lastClick, now.timeIntervalSince(last.time) < 0.4,
               distance(last.location, drag.location) < 8 {
                interaction.lastClick = nil
                model.addKey(time: geometry.time(at: drag.location.x), value: geometry.value(at: drag.location.y))
            } else {
                interaction.lastClick = (now, drag.location)
                model.selectedKey = nil
            }
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

/// Each part's progress as the overlay plays it: forward-only for closing.
enum PlayedProgress {
    static func played(_ motion: NotchMorph.Motion) -> (Double) -> [Double] {
        guard motion.isMonotonic else { return { [motion.width.value(at: $0), motion.height.value(at: $0)] } }
        // Forward-only: the running maximum, never past the end.
        let step = 1.0 / 240
        var samples: [(Double, Double)] = []
        var width = 0.0
        var height = 0.0
        var time = 0.0
        let end = motion.duration + step
        while time <= end {
            width = max(width, min(motion.width.value(at: time), 1))
            height = max(height, min(motion.height.value(at: time), 1))
            samples.append((width, height))
            time += step
        }
        return { time in
            guard !samples.isEmpty else { return [1, 1] }
            let index = min(max(Int((time / step).rounded()), 0), samples.count - 1)
            return [samples[index].0, samples[index].1]
        }
    }
}

// MARK: Sparkline

/// A motion's two curves, small: how an animation moves at a glance.
struct MotionSparkline: View {
    let motion: NotchMorph.Motion

    var body: some View {
        Canvas { context, size in
            let duration = max(motion.duration, 0.05)
            let extent = motion.extent
            let low = min(0, extent.lowerBound)
            let high = max(1, extent.upperBound)
            func point(_ time: Double, _ value: Double) -> CGPoint {
                CGPoint(x: 2 + (size.width - 4) * time / duration,
                        y: size.height - 3 - (size.height - 6) * (value - low) / (high - low))
            }
            var end = Path()
            end.move(to: point(0, 1))
            end.addLine(to: point(duration, 1))
            context.stroke(end, with: .color(.primary.opacity(0.15)), lineWidth: 1)
            for (curve, color) in [(motion.width, StudioColors.width), (motion.height, StudioColors.height)] {
                var path = Path()
                for step in 0...60 {
                    let time = duration * Double(step) / 60
                    let p = point(time, curve.value(at: time))
                    if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: Timing curve

@MainActor
final class CurveDragState: ObservableObject {
    @Published var handle: Int?
}

/// A cubic Bézier timing curve with its two control points to drag.
struct TimingCurveEditor: View {
    let title: String
    let curve: TimingCurve
    let onBegin: () -> Void
    let onChange: (TimingCurve) -> Void
    let onEnd: () -> Void
    @StateObject private var drag = CurveDragState()
    private let low = -0.6
    private let high = 1.6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Menu {
                    ForEach(TimingCurve.named, id: \.name) { preset in
                        Button(readable(preset.name)) { onBegin(); onChange(preset.curve); onEnd() }
                    }
                    Button("Overshoot") { onBegin(); onChange(TimingCurve(0.34, 1.56, 0.64, 1)); onEnd() }
                    Button("Linear") { onBegin(); onChange(.linear); onEnd() }
                } label: {
                    Text(TimingCurve.named.first { $0.curve == curve }.map { readable($0.name) } ?? "Custom")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                let frame = CGRect(x: (proxy.size.width - side) / 2 + 8, y: 8, width: side - 16, height: side - 16)
                Canvas { context, _ in draw(in: &context, frame: frame) }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in changed(value, frame: frame) }
                        .onEnded { _ in
                            if drag.handle != nil { onEnd() }
                            drag.handle = nil
                        })
            }
            .aspectRatio(1, contentMode: .fit)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(curve.controlPoints.map { String(format: "%.2f", $0) }.joined(separator: ", "))
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func readable(_ name: String) -> String {
        switch name {
        case "easeIn": "Ease In"
        case "easeOut": "Ease Out"
        case "easeInOut": "Ease In-Out"
        default: name.capitalized
        }
    }

    private func point(_ x: Double, _ y: Double, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + frame.width * x, y: frame.maxY - frame.height * (y - low) / (high - low))
    }

    private func draw(in context: inout GraphicsContext, frame: CGRect) {
        var box = Path()
        box.addRect(CGRect(origin: point(0, 1, in: frame), size: CGSize(width: frame.width,
                                                                          height: point(0, 0, in: frame).y - point(0, 1, in: frame).y)))
        context.stroke(box, with: .color(.primary.opacity(0.12)), lineWidth: 1)
        var curvePath = Path()
        for step in 0...100 {
            let x = Double(step) / 100
            let p = point(x, curve.value(at: x), in: frame)
            if step == 0 { curvePath.move(to: p) } else { curvePath.addLine(to: p) }
        }
        let start = point(0, 0, in: frame)
        let end = point(1, 1, in: frame)
        let first = point(curve.x1, curve.y1, in: frame)
        let second = point(curve.x2, curve.y2, in: frame)
        var arms = Path()
        arms.move(to: start)
        arms.addLine(to: first)
        arms.move(to: end)
        arms.addLine(to: second)
        context.stroke(arms, with: .color(.primary.opacity(0.35)), lineWidth: 1)
        context.stroke(curvePath, with: .color(StudioColors.width), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        for (index, handle) in [first, second].enumerated() {
            let radius: CGFloat = drag.handle == index ? 6.5 : 5.5
            let circle = Path(ellipseIn: CGRect(x: handle.x - radius, y: handle.y - radius, width: radius * 2, height: radius * 2))
            context.fill(circle, with: .color(.white))
            context.stroke(circle, with: .color(StudioColors.width), lineWidth: 2)
        }
    }

    private func changed(_ value: DragGesture.Value, frame: CGRect) {
        if drag.handle == nil {
            let first = point(curve.x1, curve.y1, in: frame)
            let second = point(curve.x2, curve.y2, in: frame)
            let d1 = hypot(first.x - value.startLocation.x, first.y - value.startLocation.y)
            let d2 = hypot(second.x - value.startLocation.x, second.y - value.startLocation.y)
            guard min(d1, d2) < 16 else { return }
            drag.handle = d1 <= d2 ? 0 : 1
            onBegin()
        }
        let x = min(max(Double((value.location.x - frame.minX) / frame.width), 0), 1)
        let y = min(max(low + Double((frame.maxY - value.location.y) / frame.height) * (high - low),
                        AnimationLimits.curveY.lowerBound), AnimationLimits.curveY.upperBound)
        let rx = (x * 100).rounded() / 100
        let ry = (y * 100).rounded() / 100
        onChange(drag.handle == 0 ? TimingCurve(rx, ry, curve.x2, curve.y2) : TimingCurve(curve.x1, curve.y1, rx, ry))
    }
}

// MARK: Content timeline

/// When each part of the content moves, against the outline's own motions.
struct ContentTimeline: View {
    let animation: DropyAnimation

    var body: some View {
        Canvas { context, size in
            let c = animation.content
            let open = animation.morph.open.duration
            let close = animation.morph.close.duration
            let rows: [(String, Double, Double, Color)] = [
                ("Outline opens", 0, open, .primary.opacity(0.35)),
                ("Content appears", c.revealDelay, c.revealDelay + c.revealDuration, StudioColors.width),
                ("Last piece lands", c.revealDelay + c.staggerSpan, c.revealDelay + c.staggerSpan + c.revealDuration,
                 StudioColors.width.opacity(0.55)),
                ("Blur clears", c.revealDelay, c.blurRadius > 0 ? c.revealDelay + c.revealDuration : c.revealDelay, .purple),
                ("New layout fades up", 0.04, 0.04 + c.relayoutDuration, StudioColors.height.opacity(0.7)),
                ("Content leaves", 0, c.hideDuration, StudioColors.height),
                ("Outline closes", 0, close, .primary.opacity(0.35)),
            ]
            let total = max(rows.map(\.2).max() ?? 1, 0.3) * 1.1
            let left: CGFloat = 132
            let right: CGFloat = 16
            let width = size.width - left - right
            let rowHeight = min(30, (size.height - 30) / CGFloat(rows.count))
            for (index, row) in rows.enumerated() {
                let y = 10 + CGFloat(index) * rowHeight + (index >= 5 ? 10 : 0)
                context.draw(Text(row.0).font(.system(size: 11)).foregroundColor(.secondary),
                             at: CGPoint(x: left - 10, y: y + rowHeight / 2), anchor: .trailing)
                let start = left + width * CGFloat(row.1 / total)
                let end = left + width * CGFloat(row.2 / total)
                if end - start > 0.5 {
                    let bar = Path(roundedRect: CGRect(x: start, y: y + 6, width: end - start, height: rowHeight - 12), cornerRadius: 4)
                    context.fill(bar, with: .color(row.3))
                    context.draw(Text(String(format: "%.2f–%.2f s", row.1, row.2)).font(.system(size: 9).monospacedDigit())
                        .foregroundColor(.secondary), at: CGPoint(x: end + 6, y: y + rowHeight / 2), anchor: .leading)
                } else {
                    context.draw(Text(index == 3 ? "no blur" : "—").font(.system(size: 9)).foregroundColor(.secondary),
                                 at: CGPoint(x: start, y: y + rowHeight / 2), anchor: .leading)
                }
            }
            var divider = Path()
            let dividerY = 10 + 5 * rowHeight + 5
            divider.move(to: CGPoint(x: 12, y: dividerY))
            divider.addLine(to: CGPoint(x: size.width - right, y: dividerY))
            context.stroke(divider, with: .color(.primary.opacity(0.08)), lineWidth: 1)
            context.draw(Text("Closing").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary),
                         at: CGPoint(x: 12, y: dividerY + 8), anchor: .leading)
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
