import AppKit
import Metal
import QuartzCore
import SwiftUI

/// The colour bloom that plays over the window when a tab opens.
///
/// **What it is.** One pass of the background loop Dia's hero runs: four soft colour blooms rising
/// through the frame, fading in as they arrive and fading out as they leave. It is deliberately the
/// only animation of its kind in the app — a bloom that stayed on screen would be a decoration
/// competing with the terminal's own output, so it plays once, for `Theme.Motion.chromaBloom`, and
/// then the surface stops and the view is removed. Nothing draws when a tab is not opening.
///
/// **Why Metal.** It is a per-pixel field with soft edges over the whole window — four elliptical
/// falloffs, warped by noise, at the window's own resolution. Core Animation can do a moving
/// gradient but not the noise-warped edge that makes this read as light rather than as a circle, and
/// the honest alternative (a looping video, which is what the reference site actually ships) would
/// put a decoder and a few megabytes of asset in the bundle for two seconds of soft colour.
///
/// **Why the shader is compiled from a string.** There is no `.metal` file, and therefore no
/// `default.metallib` in the bundle: SwiftPM has no Metal compile step wired up for this target, and
/// a shader that only builds under an Xcode project is a shader that breaks `swift build`. The source
/// lives below and is compiled once, on the first bloom, and the pipeline is kept — a few
/// milliseconds, paid on the frame a tab opens rather than at launch.
///
/// **Why not `MTKView`.** `MTKView` renders through `MTKViewDelegate`, which is not main-actor
/// annotated, so a delegate method in this app would have to be `nonisolated` and hop back — for a
/// view whose every frame is drawn on the main thread anyway. A layer-backed `NSView` with a
/// `CAMetalLayer` and a `CADisplayLink` is the same thing with no hop and no protocol to satisfy.
///
/// It holds no model state. Whether a bloom should be playing is `AppCore`'s — this is handed a
/// duration and told what to do when the pass is over.
struct ChromaBloomView: NSViewRepresentable {
    let duration: TimeInterval

    /// Called once, when the pass is over. `AppCore` clears the trigger with it, which is what
    /// removes this view — the animation does not hide itself.
    let onFinished: @MainActor () -> Void

    func makeNSView(context: Context) -> ChromaBloomSurface {
        ChromaBloomSurface(duration: duration, onFinished: onFinished)
    }

    func updateNSView(_ view: ChromaBloomSurface, context: Context) {}
}

/// The surface a bloom is drawn on.
///
/// One pass and then it stops: the display link is invalidated, the last frame has already faded to
/// nothing, and `onFinished` takes the view out of the hierarchy. It is never paused and resumed —
/// a new tab is a new surface, because the identity of the view is the moment it started.
@MainActor
final class ChromaBloomSurface: NSView {
    /// The shape of one frame's uniforms. **The layout is the shader's**, so the two have to agree:
    /// `float2` then two `float`s, which is 16 bytes with the alignment `float2` asks for, and the
    /// same 16 in Swift. A mismatch here is a bloom drawn from the wrong numbers rather than a
    /// compile error.
    private struct BloomUniforms {
        var size: SIMD2<Float>
        var time: Float
        var progress: Float
    }

    private let duration: TimeInterval
    private let onFinished: @MainActor () -> Void

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?

    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var hasFinished = false

    /// The compiled pipeline, kept for the next tab. Building it is milliseconds, but they are
    /// milliseconds on the frame a tab opens, and the shader is the same one every time.
    private static var sharedPipeline: MTLRenderPipelineState?

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    init(duration: TimeInterval, onFinished: @MainActor @escaping () -> Void) {
        self.duration = duration
        self.onFinished = onFinished
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()
        pipeline = device.flatMap { ChromaBloomSurface.pipeline(for: $0) }

        super.init(frame: .zero)

        wantsLayer = true
        metalLayer?.device = device
        metalLayer?.pixelFormat = .bgra8Unorm
        // The window is transparent and the bloom is a wash over what is under it, so the layer has to
        // be too — an opaque layer here would paint black over the terminal.
        metalLayer?.isOpaque = false
        metalLayer?.framebufferOnly = true

        start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ChromaBloomSurface is made in code") }

    /// The bloom is light on a window, not a control on it. `allowsHitTesting(false)` is set where it
    /// is placed; this is the same answer from the view's own side, so a bloom can never eat a click
    /// on the terminal underneath it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    /// A bloom that outlives its view — a tab closed mid-fade, a window going away — stops here
    /// rather than ticking against a layer that is no longer on screen.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stop() }
    }

    // MARK: - The pass

    private func start() {
        updateDrawableSize()

        // **Reduce Motion means no bloom.** It is decorative, it is the only thing in this app that
        // moves on its own, and somebody who has asked the system for less movement has already
        // answered the question this animation would be asking.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            pipeline != nil
        else {
            finish()
            return
        }

        startedAt = CACurrentMediaTime()
        // The link holds its target, which is this view: it is invalidated when the pass ends or when
        // the view leaves its window, and those are the only two ways this stops.
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - startedAt
        render(elapsed: elapsed)
        if elapsed >= duration { finish() }
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func finish() {
        stop()
        guard !hasFinished else { return }
        hasFinished = true
        // **Deferred, not called here.** This runs on the first frame of a pass that could not start —
        // which is inside the SwiftUI update that created the view — and clearing the trigger from
        // there is a mutation of observable state during a view update. One turn of the run loop puts
        // it after the update, which is where every later bloom's call already lands.
        let onFinished = self.onFinished
        DispatchQueue.main.async { onFinished() }
    }

    private func updateDrawableSize() {
        guard let metalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(
            width: max(bounds.width * scale, 1),
            height: max(bounds.height * scale, 1))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }

    /// How much of the bloom is showing at `elapsed`. It arrives in about a sixth of the pass and
    /// leaves over the last half, so what the eye gets is colour that fades *up* rather than
    /// something that appears at full strength and is switched off.
    private static func envelope(_ fraction: Double) -> Double {
        let arriving = smoothstep(0, 0.16, fraction)
        let leaving = 1 - smoothstep(0.55, 1, fraction)
        return arriving * leaving
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func render(elapsed: TimeInterval) {
        guard let metalLayer, let commandQueue, let pipeline,
            let drawable = metalLayer.nextDrawable(),
            let buffer = commandQueue.makeCommandBuffer()
        else { return }

        var uniforms = BloomUniforms(
            size: SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height)),
            time: Float(elapsed),
            progress: Float(ChromaBloomSurface.envelope(elapsed / duration)))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        // Cleared to nothing and drawn over: the layer is not opaque, so what is not bloom is the
        // terminal showing through rather than a black rectangle.
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BloomUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    // MARK: - The shader

    private static func pipeline(for device: MTLDevice) -> MTLRenderPipelineState? {
        if let sharedPipeline { return sharedPipeline }

        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
            let vertexFunction = library.makeFunction(name: "chroma_bloom_vertex"),
            let fragmentFunction = library.makeFunction(name: "chroma_bloom_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        let attachment = descriptor.colorAttachments[0]
        attachment?.pixelFormat = .bgra8Unorm
        // Premultiplied source-over, which is the convention the fragment shader returns: it hands
        // back colour already multiplied by its own alpha, so the factors are `one` and
        // `oneMinusSourceAlpha` rather than `sourceAlpha`.
        attachment?.isBlendingEnabled = true
        attachment?.rgbBlendOperation = .add
        attachment?.alphaBlendOperation = .add
        attachment?.sourceRGBBlendFactor = .one
        attachment?.sourceAlphaBlendFactor = .one
        attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let built = try? device.makeRenderPipelineState(descriptor: descriptor)
        sharedPipeline = built
        return built
    }

    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct BloomUniforms {
            float2 size;
            float time;
            float progress;
        };

        struct BloomVertex {
            float4 position [[position]];
            float2 uv;
        };

        // One oversized triangle rather than two: it covers the viewport with three vertices, needs
        // no vertex buffer, and has no diagonal seam for the blending to show.
        vertex BloomVertex chroma_bloom_vertex(uint vertexID [[vertex_id]]) {
            const float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            BloomVertex out;
            out.position = float4(corners[vertexID], 0.0, 1.0);
            out.uv = corners[vertexID] * 0.5 + 0.5;
            return out;
        }

        // Value noise, for the edge of a bloom. Cheap on purpose: it runs at the window's size, once
        // per bloom, and a smooth ellipse with a clean edge reads as a circle drawn on the screen
        // rather than as light arriving.
        static float bloom_hash(float2 p) {
            return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
        }

        static float bloom_noise(float2 p) {
            float2 cell = floor(p);
            float2 f = fract(p);
            float2 u = f * f * (3.0 - 2.0 * f);
            float a = bloom_hash(cell);
            float b = bloom_hash(cell + float2(1.0, 0.0));
            float c = bloom_hash(cell + float2(0.0, 1.0));
            float d = bloom_hash(cell + float2(1.0, 1.0));
            return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
        }

        // The four colours, and the only place they are written down. Returned by index rather than
        // read out of an array so the loop below stays a loop over indices the compiler can unroll.
        static float3 bloom_colour(int index) {
            if (index == 0) { return float3(0.776, 0.475, 0.769); }   // #c679c4
            if (index == 1) { return float3(0.980, 0.239, 0.114); }   // #fa3d1d
            if (index == 2) { return float3(1.000, 0.690, 0.020); }   // #ffb005
            return float3(0.012, 0.345, 0.969);                       // #0358f7
        }

        fragment float4 chroma_bloom_fragment(BloomVertex in [[stage_in]],
                                              constant BloomUniforms &uniforms [[buffer(0)]]) {
            // Aspect-corrected, so a bloom is a round bloom in a wide window rather than a smear.
            float aspect = max(uniforms.size.x, 1.0) / max(uniforms.size.y, 1.0);
            float2 p = float2(in.uv.x * aspect, in.uv.y);

            float3 colour = float3(0.0);
            float weight = 0.0;

            for (int i = 0; i < 4; ++i) {
                float index = float(i);
                // Each bloom rises at its own rate from its own starting height, so the four never
                // line up into a pattern. The rise is what the eye reads as "up".
                float rise = fract(uniforms.time * 0.30 + index * 0.27);
                float2 centre = float2((0.16 + 0.23 * index) * aspect, 1.25 - rise * 1.55);
                float2 offset = (p - centre) / float2(0.44 * aspect, 0.34);
                float radius = length(offset);
                radius += (bloom_noise(p * 2.6 + float2(index * 9.0, uniforms.time * 0.4)) - 0.5) * 0.50;
                float bloom = 1.0 - smoothstep(0.00, 1.15, radius);
                colour += bloom_colour(i) * bloom;
                weight += bloom;
            }

            // Averaged rather than summed. Four overlapping blooms added together saturate to white in
            // the middle, which is the one thing the reference's background never does — the colours
            // stay colours as they cross.
            colour = colour / max(weight, 0.0001);
            // 0.42 is how strong the bloom gets at its peak. It is the one number to lower if this
            // ever reads as too much over a light terminal — the falloff below reaches zero at 1.15
            // rather than at 1.0 so a bloom has no edge to see, which is what stops four of them
            // reading as four ellipses rather than as one field of colour.
            float alpha = min(weight, 1.0) * 0.42 * uniforms.progress;
            return float4(colour * alpha, alpha);
        }
        """
}
