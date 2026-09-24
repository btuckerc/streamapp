import AppKit
import ImageIO
import CoreImage
import CoreMedia
import CoreVideo
import CoreText
import Metal

/// Capture callbacks replace one latest frame, never enqueue a backlog.
final class RenderInputs: @unchecked Sendable {
    struct Snapshot {
        let configuration: StudioConfiguration
        let screen: CVPixelBuffer?
        let camera: CVPixelBuffer?
        let chat: CGImage?
        let backgroundImage: CGImage?
        let generation: UInt64
        let reduceMotion: Bool
    }
    private let lock = NSLock()
    private let imageQueue = DispatchQueue(label: "streamapp.background-image-loader", qos: .utility)
    private var configuration = StudioConfiguration()
    private var screen: CVPixelBuffer?
    private var camera: CVPixelBuffer?
    private var chat: CGImage?
    private var backgroundImage: CGImage?
    private var backgroundImagePath = ""
    private var imageRequest: UInt64 = 0
    private var wallpaperRequest: UInt64 = 0
    private var wallpaperSource: WallpaperSnapshotSource?
    private var generation: UInt64 = 0
    private var failure: String?
    private var reduceMotion = false
    func setReduceMotion(_ value: Bool) { lock.lock(); if reduceMotion != value { reduceMotion = value; generation &+= 1 }; lock.unlock() }
    func configure(_ value: StudioConfiguration) {
        lock.lock()
        let wallpaperChanged = configuration.backgroundStyle != value.backgroundStyle || configuration.displayID != value.displayID || configuration.windowID != value.windowID || configuration.dockFitRegion != value.dockFitRegion
        let imageChanged = configuration.backgroundStyle != value.backgroundStyle || configuration.backgroundImagePath != value.backgroundImagePath
        if (value.backgroundStyle == .mirror && wallpaperChanged) || (value.backgroundStyle != .mirror && imageChanged) {
            backgroundImage = nil
            backgroundImagePath = ""
        }
        configuration = value
        generation &+= 1
        if imageChanged { imageRequest &+= 1 }
        if wallpaperChanged { wallpaperRequest &+= 1 }
        let request = imageRequest
        let wallpaperRequest = self.wallpaperRequest
        let needsSourceReset = wallpaperChanged
        if !value.cameraEnabled { camera = nil }
        lock.unlock()

        // All WallpaperAgent/AppKit work is owned by the main queue. A new
        // token makes callbacks from a previous source harmless.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.imageRequest == request, self.wallpaperRequest == wallpaperRequest else { self.lock.unlock(); return }
            let existing = self.wallpaperSource
            if value.backgroundStyle != .mirror {
                self.wallpaperSource = nil
                self.lock.unlock()
                existing?.stop()
                self.prepareImage(path: value.backgroundStyle == .image ? value.backgroundImagePath : "", request: request)
                return
            }
            if let existing, !needsSourceReset {
                self.lock.unlock()
                existing.configure(value)
                return
            }
            self.wallpaperSource = nil
            self.lock.unlock()
            existing?.stop()
            // Initial nil is synchronous; construct outside the lock.
            let source = WallpaperSnapshotSource(configuration: value) { [weak self] image in
                self?.acceptWallpaper(image, request: wallpaperRequest)
            }
            self.lock.lock()
            guard self.imageRequest == request, self.wallpaperRequest == wallpaperRequest else { self.lock.unlock(); source.stop(); return }
            self.wallpaperSource = source
            self.lock.unlock()
        }
    }
    private func prepareImage(path: String, request: UInt64) {
        lock.lock()
        guard imageRequest == request else { lock.unlock(); return }
        guard backgroundImagePath != path else { lock.unlock(); return }
        backgroundImagePath = path
        backgroundImage = nil
        generation &+= 1
        lock.unlock()
        guard !path.isEmpty else { return }
        imageQueue.async { [weak self] in
            guard let self else { return }
            let image = Self.loadBackgroundImage(at: path)
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.backgroundImagePath == path, self.imageRequest == request else { return }
            self.backgroundImage = image
            self.generation &+= 1
        }
    }
    private func acceptWallpaper(_ image: CGImage?, request: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard wallpaperRequest == request, configuration.backgroundStyle == .mirror else { return }
        backgroundImage = image
        backgroundImagePath = ""
        generation &+= 1
    }
    private static func loadBackgroundImage(at path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ] as CFDictionary)
    }
    func setScreen(_ value: CVPixelBuffer?) { lock.lock(); screen = value; generation &+= 1; lock.unlock() }
    func setCamera(_ value: CVPixelBuffer?) { lock.lock(); camera = value; generation &+= 1; lock.unlock() }
    func setChat(_ value: CGImage?) { lock.lock(); chat = value; generation &+= 1; lock.unlock() }
    func fail(_ message: String) { lock.lock(); if failure == nil { failure = message }; lock.unlock() }
    var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return Snapshot(configuration: configuration, screen: screen, camera: camera, chat: chat, backgroundImage: backgroundImage, generation: generation, reduceMotion: reduceMotion) }
}

final class FrameRenderer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "streamapp.compositor", qos: .userInitiated)
    private let inputs: RenderInputs
    private let preview: PreviewFrames
    private let encoder: VideoEncoder?
    private let context: CIContext
    private let synthetic: Bool
    private var timer: DispatchSourceTimer?
    private var frame: Int64 = 0
    private var startedAt: TimeInterval?
    private var composite: CVPixelBuffer?
    private var previewPool: CVPixelBufferPool?
    private var renderedGeneration: UInt64?
    private var transition = SceneTransition()
    /// Static backgrounds (mirrored wallpaper, chosen image) are baked once per source/geometry
    /// change into GPU memory, so recomposed frames neither re-upload nor re-scale them.
    private struct BackgroundKey: Equatable {
        let style: BackgroundStyle
        let imageID: ObjectIdentifier?
        let canvas: CGRect
        let sourceExtent: CGRect
        let red: Double
        let green: Double
        let blue: Double
    }
    private var backgroundKey: BackgroundKey?
    /// Retained so `imageID` cannot be reused by a different image.
    private var backgroundSourceImage: CGImage?
    private var bakedBackground: CIImage?
    /// The latest chat snapshot, uploaded once rather than on every composed frame.
    private var chatSource: CGImage?
    private var chatImage: CIImage?
    private var chatPool: CVPixelBufferPool?
    private var chatPoolSize = CGSize.zero
    /// One camera-local geometry recipe, never a captured or composed frame.
    private struct CameraSurfaceKey: Equatable {
        let size: CGSize
        let radius: CGFloat
    }
    private struct CameraSurface {
        let key: CameraSurfaceKey
        let mask: CIImage
        let shadow: CIImage
    }
    private var cameraSurface: CameraSurface?
    private var renderedGeometry: SceneGeometry?
    private let extent = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let color = CGColorSpace(name: CGColorSpace.sRGB)!
    private let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private lazy var cameraOff = resident(Self.slate("CAMERA OFF", subtitle: "Enable your webcam to appear here", width: 1920, height: 1080, color: (0.06, 0.07, 0.09)))
    private lazy var waiting = resident(Self.slate("WAITING FOR SOURCE", subtitle: "No screen image is being substituted", width: 1920, height: 1080, color: (0.05, 0.08, 0.12)))
    private lazy var chatWaiting = resident(Self.slate("CHAT", subtitle: "Connecting…", width: 384, height: 1080, color: (0, 0, 0), transparent: true))
    private lazy var syntheticDesktop = resident(Self.slate("SYNTHETIC DESKTOP", subtitle: "StreamApp · 1920 × 1080 · 30 fps", width: 1920, height: 1080, color: (0.03, 0.12, 0.22)))
    private lazy var syntheticFace = resident(Self.slate("SYNTHETIC CAMERA", subtitle: "No camera device is open", width: 1920, height: 1080, color: (0.28, 0.12, 0.42), textured: true))
    private lazy var syntheticChat = resident(Self.slate("# CHAT", subtitle: "Crisp over blurred video", width: 384, height: 1080, color: (0, 0, 0), transparent: true))

    init(inputs: RenderInputs, preview: PreviewFrames, outputFD: Int32?, synthetic: Bool) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw EngineError.message("Metal is unavailable") }
        self.inputs = inputs; self.preview = preview; self.synthetic = synthetic
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        encoder = try outputFD.map { try VideoEncoder(outputFD: $0) }
    }
    

    func start(epoch: TimeInterval) {
        startedAt = epoch
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.render() }
        self.timer = timer; timer.resume()
    }
    func finish() async throws -> Int64 {
        timer?.cancel(); timer = nil
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.encoder?.finish()
                    self.composite = nil
                    self.preview.publish(nil)
                    continuation.resume(returning: self.frame)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func render() {
        guard inputs.error == nil else { return }
        let snapshot = inputs.snapshot()
        if encoder == nil {
            guard let mode = preview.mode else { return }
            if mode == .camera && !synthetic {
                preview.publish(snapshot.configuration.cameraEnabled ? snapshot.camera : nil, mirrored: snapshot.configuration.mirrorCamera)
                return
            }
        }
        do {
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            if startedAt == nil { startedAt = now }
            if encoder != nil && now - startedAt! - Double(frame) / 30 >= 0.2 {
                throw EngineError.message("Video timing fell behind; stopping to preserve audio synchronization")
            }
            let target = SceneGeometry(configuration: snapshot.configuration)
            let geometry = transition.sample(target: target, now: now, reduceMotion: snapshot.reduceMotion)
            if synthetic || composite == nil || renderedGeneration != snapshot.generation || renderedGeometry != geometry {
                let buffer: CVPixelBuffer
                if let encoder { buffer = try encoder.makePixelBuffer() }
                else {
                    guard let available = try makePreviewBuffer() else { return }
                    buffer = available
                }
                context.render(compose(snapshot, geometry: geometry, settled: geometry == target), to: buffer, bounds: extent, colorSpace: color)
                composite = buffer
                renderedGeneration = snapshot.generation
                renderedGeometry = geometry
            }
            guard let composite else { throw EngineError.message("No composed frame") }
            try encoder?.encode(composite, pts: CMTime(value: frame, timescale: 30))
            frame += 1
            if let mode = preview.mode {
                switch mode {
                case .program: preview.publish(composite)
                case .camera: preview.publish(snapshot.configuration.cameraEnabled ? snapshot.camera : nil, mirrored: snapshot.configuration.mirrorCamera)
                }
            }
        } catch { inputs.fail("Video pipeline: \(error)") }
    }
    private func compose(_ snapshot: RenderInputs.Snapshot, geometry g: SceneGeometry, settled: Bool) -> CIImage {
        let c = snapshot.configuration
        var camera = c.cameraEnabled ? (synthetic ? syntheticFace : snapshot.camera.map { CIImage(cvPixelBuffer: $0) }) : nil
        if let image = camera, c.mirrorCamera {
            camera = image.transformed(by: CGAffineTransform(translationX: image.extent.minX + image.extent.maxX, y: 0).scaledBy(x: -1, y: 1))
        }
        var desktop = synthetic ? syntheticDesktop : snapshot.screen.map { CIImage(cvPixelBuffer: $0) } ?? waiting
        if synthetic {
            let marker = CIImage(color: CIColor(red: 0.1, green: 0.8, blue: 0.8)).cropped(to: CGRect(x: CGFloat((frame * 8) % 1800), y: 140, width: 90, height: 90))
            desktop = marker.composited(over: desktop)
        }
        var preparedBackground: CIImage?
        if DesktopBackgroundRenderer.isStatic(c.backgroundStyle) {
            // Mid-transition the canvas moves every frame; draw the recipe directly then.
            if settled {
                let key = BackgroundKey(style: c.backgroundStyle, imageID: snapshot.backgroundImage.map { ObjectIdentifier($0) }, canvas: g.desktop, sourceExtent: desktop.extent, red: c.backgroundRed, green: c.backgroundGreen, blue: c.backgroundBlue)
                if key != backgroundKey {
                    backgroundKey = key
                    backgroundSourceImage = snapshot.backgroundImage
                    bakedBackground = Self.resident(DesktopBackgroundRenderer.background(source: desktop, in: g.desktop, configuration: c, image: snapshot.backgroundImage),
                                                    in: g.desktop, context: context, colorSpace: color)
                }
                preparedBackground = bakedBackground
            }
        } else {
            backgroundKey = nil
            backgroundSourceImage = nil
            bakedBackground = nil
        }
        var image = DesktopBackgroundRenderer.compose(source: desktop, in: g.desktop, configuration: c, image: snapshot.backgroundImage, preparedBackground: preparedBackground)
        if let camera, g.overlay >= 1 {
            image = fit(camera, into: g.camera, fill: true).composited(over: image)
        } else if let camera {
            let strength = max(0, min(1, 1 - g.overlay))
            let shortSide = min(g.camera.width, g.camera.height)
            let radius = (c.cameraFrame == .circle ? shortSide / 2 : shortSide * 0.08) * strength
            let geometry = cameraSurfaceGeometry(size: g.camera.size, radius: radius)
            let placement = CGAffineTransform(translationX: g.camera.midX, y: g.camera.midY)
            let shadow = opacity(geometry.shadow, 0.18 * strength).transformed(by: placement)
            image = shadow.composited(over: image)
            let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: g.camera)
            let rounded = fit(camera, into: g.camera, fill: true)
                .applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: transparent,
                    kCIInputMaskImageKey: geometry.mask.transformed(by: placement)
                ])
            image = rounded.composited(over: image)
        } else if g.overlay > 0 {
            // No cached face or face-shaped intermediate survives camera-off.
            image = opacity(cameraOff, g.overlay).composited(over: image)
        }
        guard c.chatEnabled, g.chat.width > 0 else { return image.cropped(to: extent) }
        let chat = synthetic ? syntheticChat : snapshot.chat.map(residentChat) ?? chatWaiting
        let opaquePanel = CIImage(color: CIColor(red: 0.07, green: 0.09, blue: 0.13)).cropped(to: g.chat)
        var panel = opaquePanel
        if g.overlay > 0 {
            let glass = CIImage(color: CIColor(red: 0.025, green: 0.035, blue: 0.06, alpha: 0.48))
                .cropped(to: g.chat).composited(over: blurred(image, in: g.chat))
            panel = opacity(glass, g.overlay).composited(over: opaquePanel)
        }
        image = panel.composited(over: image)
        return fit(chat, into: g.chat, fill: false).composited(over: image).cropped(to: extent)
    }
    private func cameraSurfaceGeometry(size: CGSize, radius: CGFloat) -> CameraSurface {
        let key = CameraSurfaceKey(size: size, radius: radius)
        if let cameraSurface, cameraSurface.key == key { return cameraSurface }
        let aperture = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        let shadowBounds = aperture.insetBy(dx: -38, dy: -38)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: shadowBounds)
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: aperture),
            kCIInputRadiusKey: radius,
            "inputColor": CIColor.white
        ])!.outputImage!.composited(over: clear).cropped(to: shadowBounds)
        let shadow = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12])
            .transformed(by: CGAffineTransform(translationX: 0, y: -2))
            .cropped(to: shadowBounds)
        let surface = CameraSurface(key: key, mask: mask, shadow: shadow)
        cameraSurface = surface
        return surface
    }
    private func opacity(_ image: CIImage, _ value: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: value)])
    }
    /// Blur only the panel plus its kernel halo, at quarter resolution on Metal.
    /// The full camera stays sharp and the chat foreground never enters this filter.
    private func blurred(_ image: CIImage, in rect: CGRect) -> CIImage {
        let region = rect.insetBy(dx: -48, dy: -48).intersection(extent)
        let small = image.cropped(to: region).clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 5])
        return small.transformed(by: CGAffineTransform(scaleX: 4, y: 4)).cropped(to: rect)
    }
    private func fit(_ image: CIImage, into rect: CGRect, fill: Bool) -> CIImage {
        let x = rect.width / image.extent.width; let y = rect.height / image.extent.height
        let scale = fill ? max(x, y) : min(x, y)
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        return normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: rect.minX + (rect.width - image.extent.width * scale) / 2, y: rect.minY + (rect.height - image.extent.height * scale) / 2)).cropped(to: rect)
    }
    private func resident(_ image: CIImage) -> CIImage {
        Self.resident(image, in: image.extent, context: context, colorSpace: color)
    }
    private func residentChat(_ source: CGImage) -> CIImage {
        if let chatImage, chatSource === source { return chatImage }
        let size = CGSize(width: source.width, height: source.height)
        if chatPool == nil || chatPoolSize != size {
            var attributes = Self.residentAttributes
            attributes[kCVPixelBufferWidthKey as String] = source.width
            attributes[kCVPixelBufferHeightKey as String] = source.height
            attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
            chatPool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &chatPool)
            chatPoolSize = size
        }
        let image = Self.resident(CIImage(cgImage: source), in: CGRect(origin: .zero, size: size), context: context, colorSpace: color, pool: chatPool)
        chatSource = source; chatImage = image
        return image
    }
    private static let residentAttributes: [String: Any] = [
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
    ]
    /// Renders a static layer once into an IOSurface so later frames sample GPU memory instead of
    /// re-uploading a CPU bitmap (about 1 ms of CPU per 1080p layer per frame). Falls back to the
    /// recipe itself if a buffer cannot be allocated.
    static func resident(_ image: CIImage, in rect: CGRect, context: CIContext, colorSpace: CGColorSpace, pool: CVPixelBufferPool? = nil) -> CIImage {
        let bounds = rect.integral
        guard bounds.width > 0, bounds.height > 0 else { return image }
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        else { CVPixelBufferCreate(nil, Int(bounds.width), Int(bounds.height), kCVPixelFormatType_32BGRA, residentAttributes as CFDictionary, &buffer) }
        guard let buffer else { return image }
        let toOrigin = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        context.render(image.transformed(by: toOrigin), to: buffer, bounds: CGRect(origin: .zero, size: bounds.size), colorSpace: colorSpace)
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colorSpace])
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
    }
    private static func slate(_ title: String, subtitle: String, width: Int, height: Int, color: (CGFloat, CGFloat, CGFloat), transparent: Bool = false, textured: Bool = false) -> CIImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !transparent {
            context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        if textured {
            context.setFillColor(CGColor(red: 0.55, green: 0.3, blue: 0.65, alpha: 1))
            for x in stride(from: 0, to: width, by: 24) { context.fill(CGRect(x: x, y: 0, width: 8, height: height)) }
            context.setFillColor(CGColor(red: 0.18, green: 0.45, blue: 0.55, alpha: 1))
            for y in stride(from: 0, to: height, by: 64) { context.fill(CGRect(x: 0, y: y, width: width, height: 12)) }
        }
        for (text, size, y) in [(title, CGFloat(width > 500 ? 52 : 30), CGFloat(height) * 0.55), (subtitle, CGFloat(width > 500 ? 28 : 18), CGFloat(height) * 0.45)] {
            let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
            let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1)])
            let line = CTLineCreateWithAttributedString(string)
            let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = CGPoint(x: max(12, (Double(width) - textWidth) / 2), y: y)
            CTLineDraw(line, context)
        }
        return CIImage(cgImage: context.makeImage()!)
    }
    private func makePreviewBuffer() throws -> CVPixelBuffer? {
        if previewPool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: 1920,
                kCVPixelBufferHeightKey as String: 1080,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &previewPool) == kCVReturnSuccess else {
                throw EngineError.message("Could not create preview buffers")
            }
        }
        var buffer: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 4] as CFDictionary
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, previewPool!, limits, &buffer)
        if result == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard result == kCVReturnSuccess else { throw EngineError.message("Could not allocate preview frame") }
        return buffer
    }
}
