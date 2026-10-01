import AppKit
import CoreVideo
import IOSurface
import MetalKit
import QuartzCore
import DropyCore

/// Presents the most recent ScreenCaptureKit pixel buffer without a CPU image conversion.
/// The IOSurface-to-Metal texture path still needs end-to-end profiling before any
/// zero-copy or latency claim can be made.
final class MetalFrameView: MTKView, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var currentPixelBuffer: CVPixelBuffer?
    private let concealmentView = NSView()
    private var visibilityGeneration = UUID()
    /// Timestamps for the frame not yet drawn; attached to exactly one drawable.
    private var pendingStamp: FrameStamp?
    private var pendingGeometry: CaptureGeometry?
    /// Increments per presented frame so a late callback can tell whether it is stale.
    private var frameSequence = 0
    private var presentRetries = 0
    private var retryLadder = PresentationRetryLadder()
    private var drawableRetryTask: Task<Void, Never>?
    /// Which presentation path this view uses. `PresentationMode.retry`, the default,
    /// is the behaviour docs/BENCHMARK.md measured; the others are opt-in experiments.
    let presentMode: DropyCore.PresentationMode
    /// When to keep the display link running (`PresentationMode.warm` only).
    private var warmth = PresentationWarmth()
    private var warmthCooldown: Task<Void, Never>?
    /// Whether the view is currently drawing from its display link rather than on demand.
    private var displayLinkRunning = false
    /// One-shot callback on the main thread with the Core Animation media time at
    /// which the next captured frame reached the screen.
    var onNextPresented: (@MainActor (CFTimeInterval) -> Void)?
    var contentMode: DropyCore.ContentMode = .fit {
        didSet {
            guard contentMode != oldValue else { return }
            invalidatePresentedMapping()
            setNeedsDisplay(bounds)
        }
    }

    // MARK: Interaction (M3 prototype)
    //
    // Set only while interactive preview is on; otherwise the view ignores input as before.
    // Points are in view coordinates with a top-left origin, like the source window.

    /// A click (mouse down and up without dragging) at a point.
    var onClick: ((CGPoint) -> Void)?
    /// A scroll at a point, with AppKit's deltas (positive y scrolls toward the top).
    var onScroll: ((CGPoint, CGSize) -> Void)?
    /// Input the preview cannot send yet, such as a drag or a right-click.
    var onUnsupported: ((InputKind) -> Void)?
    private var pressPoint: CGPoint?
    private var dragged = false

    /// Pixel size of the frame on screen, or nil before the first frame.
    var presentedPixelSize: CGSize? {
        currentPixelBuffer.map { CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) }
    }
    /// Stream geometry of the frame on screen; cleared with the frame.
    private(set) var presentedGeometry: CaptureGeometry?
    private var drawnPixelSize: CGSize?
    private var lastPresentedSequence = -1

    /// The frame on screen and the geometry it was captured with, for preview input.
    var presentedFrame: PresentedFrame? {
        drawnPixelSize.map { PresentedFrame(pixelSize: $0, geometry: presentedGeometry) }
    }

    private func topLeftPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onClick != nil }

    override func mouseDown(with event: NSEvent) {
        guard onClick != nil else { return super.mouseDown(with: event) }
        if case .refuse(let kind) = PreviewPointerInput.press(clickCount: event.clickCount,
                                                              modifiers: PreviewModifiers(event.modifierFlags)) {
            pressPoint = nil
            onUnsupported?(kind)
            return
        }
        pressPoint = topLeftPoint(event)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressPoint, onClick != nil else { return super.mouseDragged(with: event) }
        let point = topLeftPoint(event)
        if !dragged, PreviewPointerInput.isDrag(from: pressPoint, to: point) {
            dragged = true
            onUnsupported?(.drag)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let press = pressPoint, let onClick else { return super.mouseUp(with: event) }
        pressPoint = nil
        if !dragged { onClick(press) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard onClick != nil else { return super.rightMouseDown(with: event) }
        onUnsupported?(.contextMenu)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let onScroll else { return super.scrollWheel(with: event) }
        switch PreviewPointerInput.scroll(delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
                                          precise: event.hasPreciseScrollingDeltas,
                                          momentum: !event.momentumPhase.isEmpty,
                                          modifiers: PreviewModifiers(event.modifierFlags)) {
        case .send(let delta): onScroll(topLeftPoint(event), delta)
        case .refuse(let kind): onUnsupported?(kind)
        case .ignore: break
        }
    }

    /// Resolved once per process. An unrecognised request keeps the measured default and
    /// says so, so a typo in a benchmark run cannot pass for the experiment it meant.
    static let environmentPresentMode: DropyCore.PresentationMode = {
        let resolution = DropyCore.PresentationMode.resolve(ProcessInfo.processInfo.environment)
        if let unrecognized = resolution.unrecognized {
            NSLog("Dropy present mode: unrecognized=\"%@\" using=%@", unrecognized, resolution.mode.rawValue)
        } else if resolution.mode != .measuredDefault {
            NSLog("Dropy present mode: %@", resolution.mode.rawValue)
        }
        return resolution.mode
    }()

    static func make(frame: CGRect,
                     presentMode: DropyCore.PresentationMode = environmentPresentMode) throws -> MetalFrameView {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw RendererError.metalUnavailable
        }
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let vertex = library.makeFunction(name: "dropyVertex"),
              let fragment = library.makeFunction(name: "dropyFragment") else {
            throw RendererError.shaderUnavailable
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        return MetalFrameView(frame: frame, metalDevice: device,
                              commandQueue: queue, pipeline: pipeline, presentMode: presentMode)
    }

    private init(frame: CGRect, metalDevice: MTLDevice,
                 commandQueue: MTLCommandQueue, pipeline: MTLRenderPipelineState,
                 presentMode: DropyCore.PresentationMode) {
        self.pipeline = pipeline
        self.commandQueue = commandQueue
        self.presentMode = presentMode
        super.init(frame: frame, device: metalDevice)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.045, green: 0.05, blue: 0.07, alpha: 1)
        framebufferOnly = true
        // Two drawables keep presentation from queueing an extra refresh behind.
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
        // Off by default: with it on, `draw(in:)` presents the drawable itself after the
        // command buffer is scheduled, inside the current Core Animation transaction.
        presentsWithTransaction = presentMode.presentsWithTransaction
        enableSetNeedsDisplay = true
        isPaused = true
        delegate = self
        concealmentView.frame = bounds
        concealmentView.autoresizingMask = [.width, .height]
        concealmentView.wantsLayer = true
        concealmentView.layer?.backgroundColor = NSColor(calibratedWhite: 0.025, alpha: 1).cgColor
        addSubview(concealmentView)
    }

    required init(coder: NSCoder) { fatalError("Use init(frame:)") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
        presentsWithTransaction = presentMode.presentsWithTransaction
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification,
                                                  object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification,
                                                   object: window)
        }
        if currentPixelBuffer != nil {
            setNeedsDisplay(bounds)
            scheduleDrawableRetry()
        }
    }

    @objc private func occlusionChanged() {
        if currentPixelBuffer != nil {
            setNeedsDisplay(bounds)
            scheduleDrawableRetry()
        }
    }

    func present(_ pixelBuffer: CVPixelBuffer, stamp: FrameStamp? = nil, geometry: CaptureGeometry? = nil) {
        precondition(Thread.isMainThread)
        // A frame replaced before any draw never reaches the screen.
        if let pendingStamp { pendingStamp.recorder.recordNotPresented(pendingStamp) }
        pendingStamp = stamp
        frameSequence += 1
        presentRetries = 0
        drawableRetryTask?.cancel()
        drawableRetryTask = nil
        retryLadder.reset()
        currentPixelBuffer = pixelBuffer
        // A pending frame does not replace the frame actually on screen. Keep its
        // mapping until a newer presentation succeeds; clear/viewport changes revoke it.
        pendingGeometry = geometry
        // A frame after a quiet gap meets the cold presentation path the latency trace
        // measures drawable misses on; in a warm mode that starts the display link.
        warmth.noteFrame(at: CACurrentMediaTime())
        applyWarmth()
        // Draw now instead of waiting for the next display cycle; the deferred
        // path showed about two refreshes of avoidable frame age.
        draw()
        // If no drawable was available, keep the frame pending for AppKit's next
        // display pass. Identical capture frames may all be skipped from here on.
        if pendingStamp != nil {
            setNeedsDisplay(bounds)
            scheduleDrawableRetry()
        }
    }

    /// Dropy just sent input to the source, so a changed frame is expected. This is the
    /// earliest warning the presentation path gets: the 2026-09-30 trace measured
    /// 64–75 ms at p50 from here to the frame arriving, which is enough time to start
    /// the display link before the frame that must not be missed is drawn.
    func noteInputSent() {
        precondition(Thread.isMainThread)
        warmth.noteInput(at: CACurrentMediaTime())
        applyWarmth()
    }

    /// `MTKView` draws on demand while `enableSetNeedsDisplay` is set and then ignores
    /// `isPaused`; the display link only runs with on-demand drawing switched off. The
    /// two flags therefore always move together, never one at a time.
    private func setDisplayLinkRunning(_ running: Bool) {
        guard displayLinkRunning != running else { return }
        displayLinkRunning = running
        if running {
            enableSetNeedsDisplay = false
            isPaused = false
        } else {
            isPaused = true
            enableSetNeedsDisplay = true
            // A frame that arrived during the warm period may still be unpresented, and
            // on-demand drawing will not pick it up by itself.
            if pendingStamp != nil { setNeedsDisplay(bounds) }
        }
    }

    /// Starts or stops the display link to match the current warmth, and schedules the
    /// cool-down. Warmth always expires, so this cannot leave the link running.
    private func applyWarmth() {
        guard presentMode.keepsDisplayLinkWarm else { return }
        let now = CACurrentMediaTime()
        // Nothing to hold warm without a frame to show; `clear()` cools as well, so a
        // closed overlay does no periodic work.
        setDisplayLinkRunning(warmth.isWarm(at: now) && currentPixelBuffer != nil)
        warmthCooldown?.cancel()
        warmthCooldown = nil
        guard displayLinkRunning, let remaining = warmth.remaining(at: now) else { return }
        let delay = max(Int((remaining * 1_000).rounded(.up)), 1)
        warmthCooldown = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.warmthCooldown = nil
            self.applyWarmth()
        }
    }

    /// Cover the old drawable even when no new drawable is available. Keeping the
    /// Metal layer visible lets it obtain drawables while the cover conceals it.
    func clear() {
        precondition(Thread.isMainThread)
        currentPixelBuffer = nil
        presentedGeometry = nil
        drawnPixelSize = nil
        lastPresentedSequence = -1
        pendingGeometry = nil
        if let pendingStamp { pendingStamp.recorder.recordNotPresented(pendingStamp) }
        pendingStamp = nil
        frameSequence += 1
        drawableRetryTask?.cancel()
        drawableRetryTask = nil
        retryLadder.reset()
        presentRetries = 0
        // Nothing is on screen to keep warm. Ending warmth here, rather than letting it
        // expire, is what keeps a closed overlay at no periodic work.
        warmth.cool()
        applyWarmth()
        visibilityGeneration = UUID()
        concealmentView.isHidden = false
        setNeedsDisplay(bounds)
    }

    private func retryPresent(_ stamp: FrameStamp, sequence: Int) {
        guard sequence == frameSequence, pendingStamp == nil,
              currentPixelBuffer != nil else {
            stamp.recorder.recordNotPresented(stamp)
            return
        }
        presentRetries += 1
        pendingStamp = stamp
        if retryLadder.redrawsImmediately(attempt: presentRetries) { setNeedsDisplay(bounds) }
        scheduleDrawableRetry()
    }

    /// A drawable can be unavailable while the panel is covered or still opening.
    /// Identical capture frames are skipped, so this frame must retry on its own.
    private func scheduleDrawableRetry() {
        guard pendingStamp != nil, drawableRetryTask == nil else { return }
        let sequence = frameSequence
        let delay = retryLadder.nextDelayMilliseconds()
        drawableRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.drawableRetryTask = nil
            guard self.frameSequence == sequence, self.pendingStamp != nil else { return }
            self.draw()
            self.scheduleDrawableRetry()
        }
    }

    /// A changed viewport must reach the screen before input uses its mapping.
    private func invalidatePresentedMapping() {
        visibilityGeneration = UUID()
        presentedGeometry = nil
        drawnPixelSize = nil
        lastPresentedSequence = -1
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        invalidatePresentedMapping()
        setNeedsDisplay(bounds)
    }

    func draw(in view: MTKView) {
        guard window?.occlusionState.contains(.visible) == true else { return }
        guard let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        // Without a usable frame, still present the cleared pass. Returning early
        // would leave the previous source's last image on screen.
        guard let pixelBuffer = currentPixelBuffer,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              let unmanagedSurface = CVPixelBufferGetIOSurface(pixelBuffer) else {
            encoder.endEncoding()
            commit(buffer, presenting: drawable)
            return
        }

        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: sourceWidth, height: sourceHeight,
            mipmapped: false)
        textureDescriptor.usage = [.shaderRead]
        guard let texture = device?.makeTexture(
            descriptor: textureDescriptor,
            iosurface: unmanagedSurface.takeUnretainedValue(), plane: 0) else {
            encoder.endEncoding()
            commit(buffer, presenting: drawable)
            return
        }

        let dw = Double(drawableSize.width)
        let dh = Double(drawableSize.height)
        let sw = Double(sourceWidth)
        let sh = Double(sourceHeight)
        let scale: Double
        switch contentMode {
        case .fit: scale = min(dw / sw, dh / sh)
        case .fill: scale = max(dw / sw, dh / sh)
        case .nativeScale, .selectedRegion: scale = 1
        }
        let viewport = MTLViewport(originX: (dw - sw * scale) / 2,
                                   originY: (dh - sh * scale) / 2,
                                   width: sw * scale, height: sh * scale,
                                   znear: 0, zfar: 1)
        encoder.setViewport(viewport)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        let geometry = pendingGeometry
        let pixels = CGSize(width: sourceWidth, height: sourceHeight)
        let stamp = pendingStamp
        pendingStamp = nil
        let generation = visibilityGeneration
        let armed = onNextPresented != nil
        let sequence = frameSequence
        let drawIndex = stamp?.beginDraw()
        drawable.addPresentedHandler { [weak self] drawable in
            let presentedTime = drawable.presentedTime
            if let stamp { stamp.recorder.recordPresented(stamp, presentedTime: presentedTime, draw: drawIndex) }
            if presentedTime == 0 {
                // The compositor never showed this drawable. Direct evidence the path is
                // cold, so a warm mode holds the display link for the redraw that follows.
                Task { @MainActor [weak self] in
                    guard let self, self.visibilityGeneration == generation,
                          self.frameSequence == sequence, self.currentPixelBuffer != nil else { return }
                    self.warmth.noteDrawableMiss(at: CACurrentMediaTime())
                    self.applyWarmth()
                    if let stamp { self.retryPresent(stamp, sequence: sequence) }
                }
                return
            }
            guard presentedTime > 0 else { return }
            Task { @MainActor [weak self] in
                guard let self, self.visibilityGeneration == generation,
                      self.currentPixelBuffer != nil, sequence >= self.lastPresentedSequence else { return }
                self.lastPresentedSequence = sequence
                self.presentedGeometry = geometry
                self.drawnPixelSize = pixels
                self.concealmentView.isHidden = true
                if armed, let reveal = self.onNextPresented {
                    self.onNextPresented = nil
                    reveal(presentedTime)
                }
            }
        }
        commit(buffer, presenting: drawable)
    }

    /// Hands the finished command buffer to the compositor.
    ///
    /// By default the drawable is presented with the buffer: Metal schedules the layer's
    /// surface swap when the buffer completes, outside any Core Animation transaction.
    /// With `presentsWithTransaction` the buffer is committed first and the drawable is
    /// presented here on the main thread instead, so the layer's contents change inside
    /// the transaction that commits them. That is the documented way to keep presentation
    /// in step with Core Animation; the cost is blocking this thread until the buffer is
    /// scheduled, which is why it is opt-in and unmeasured (see docs/BENCHMARK.md).
    private func commit(_ buffer: MTLCommandBuffer, presenting drawable: CAMetalDrawable) {
        guard presentsWithTransaction else {
            buffer.present(drawable)
            buffer.commit()
            return
        }
        buffer.commit()
        buffer.waitUntilScheduled()
        drawable.present()
    }

    enum RendererError: Error {
        case metalUnavailable
        case shaderUnavailable
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct DropyVertex { float4 position [[position]]; float2 uv; };
    vertex DropyVertex dropyVertex(uint i [[vertex_id]]) {
        const float2 positions[4] = { {-1, 1}, {1, 1}, {-1, -1}, {1, -1} };
        const float2 uvs[4] = { {0, 0}, {1, 0}, {0, 1}, {1, 1} };
        return {float4(positions[i], 0, 1), uvs[i]};
    }
    fragment float4 dropyFragment(DropyVertex in [[stage_in]],
                                  texture2d<float> image [[texture(0)]]) {
        constexpr sampler sampleFilter(coord::normalized, address::clamp_to_edge,
                                       filter::linear);
        return image.sample(sampleFilter, in.uv);
    }
    """
}

extension PreviewModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
    }
}
