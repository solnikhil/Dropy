import AppKit
import CoreVideo
import IOSurface
import MetalKit
import DropyCore

/// Presents the most recent ScreenCaptureKit pixel buffer without a CPU image conversion.
/// The IOSurface-to-Metal texture path still needs end-to-end profiling before any
/// zero-copy or latency claim can be made.
final class MetalFrameView: MTKView, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var currentPixelBuffer: CVPixelBuffer?
    private var visibilityGeneration = UUID()
    /// Timestamps for the frame not yet drawn; attached to exactly one drawable.
    private var pendingStamp: FrameStamp?
    /// Increments per presented frame so a late callback can tell whether it is stale.
    private var frameSequence = 0
    private var presentRetries = 0
    private static let maximumPresentRetries = 3
    /// One-shot callback on the main thread with the Core Animation media time at
    /// which the next captured frame reached the screen.
    var onNextPresented: (@MainActor (CFTimeInterval) -> Void)?
    var contentMode: DropyCore.ContentMode = .fit {
        didSet { setNeedsDisplay(bounds) }
    }

    static func make(frame: CGRect) throws -> MetalFrameView {
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
                              commandQueue: queue, pipeline: pipeline)
    }

    private init(frame: CGRect, metalDevice: MTLDevice,
                 commandQueue: MTLCommandQueue, pipeline: MTLRenderPipelineState) {
        self.pipeline = pipeline
        self.commandQueue = commandQueue
        super.init(frame: frame, device: metalDevice)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.045, green: 0.05, blue: 0.07, alpha: 1)
        framebufferOnly = true
        // Two drawables keep presentation from queueing an extra refresh behind.
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
        enableSetNeedsDisplay = true
        isPaused = true
        delegate = self
        alphaValue = 0
    }

    required init(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
    }

    func present(_ pixelBuffer: CVPixelBuffer, stamp: FrameStamp? = nil) {
        precondition(Thread.isMainThread)
        // A frame replaced before any draw never reaches the screen.
        pendingStamp?.recorder.recordNotPresented()
        pendingStamp = stamp
        frameSequence += 1
        presentRetries = 0
        currentPixelBuffer = pixelBuffer
        // Draw now instead of waiting for the next display cycle; the deferred
        // path showed about two refreshes of avoidable frame age.
        draw()
    }

    /// Keep the old drawable invisible even when no new drawable is available.
    /// A new frame makes the view visible only after Metal presents it.
    func clear() {
        precondition(Thread.isMainThread)
        currentPixelBuffer = nil
        pendingStamp?.recorder.recordNotPresented()
        pendingStamp = nil
        frameSequence += 1
        visibilityGeneration = UUID()
        alphaValue = 0
        setNeedsDisplay(bounds)
    }

    private func retryPresent(_ stamp: FrameStamp, sequence: Int) {
        guard sequence == frameSequence, pendingStamp == nil, currentPixelBuffer != nil,
              presentRetries < Self.maximumPresentRetries else { return }
        presentRetries += 1
        pendingStamp = stamp
        setNeedsDisplay(bounds)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        setNeedsDisplay(bounds)
    }

    func draw(in view: MTKView) {
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
            buffer.present(drawable)
            buffer.commit()
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
            buffer.present(drawable)
            buffer.commit()
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
        let stamp = pendingStamp
        pendingStamp = nil
        let generation = visibilityGeneration
        let armed = onNextPresented != nil
        let sequence = frameSequence
        drawable.addPresentedHandler { [weak self] drawable in
            let presentedTime = drawable.presentedTime
            if let stamp { stamp.recorder.recordPresented(stamp, presentedTime: presentedTime) }
            if presentedTime == 0 {
                if let stamp {
                    Task { @MainActor [weak self] in self?.retryPresent(stamp, sequence: sequence) }
                }
                return
            }
            guard presentedTime > 0 else { return }
            Task { @MainActor [weak self] in
                guard let self, self.visibilityGeneration == generation,
                      self.currentPixelBuffer != nil else { return }
                self.alphaValue = 1
                if armed, let reveal = self.onNextPresented {
                    self.onNextPresented = nil
                    reveal(presentedTime)
                }
            }
        }
        buffer.present(drawable)
        buffer.commit()
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
