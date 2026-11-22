import AppKit
import CoreImage
import CoreMedia
import os
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// A frame ready for display. Holding the pixel buffer keeps its IOSurface out of the
/// capture pool while the layer shows it.
private struct PreviewFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let surface: IOSurfaceRef
}

private final class PreviewFrames: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Effects: Sendable {
        var sharpness: Double = 0
        var lut: CubeLUT?
    }

    let effects = OSAllocatedUnfairLock(initialState: Effects())
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let delivering = OSAllocatedUnfairLock(initialState: false)
    private let deliver: @Sendable (PreviewFrame, @escaping @Sendable () -> Void) -> Void
    /// Output buffers for frames with effects; touched only on the sample handler queue.
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero

    init(deliver: @escaping @Sendable (PreviewFrame, @escaping @Sendable () -> Void) -> Void) {
        self.deliver = deliver
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = sampleBuffer.imageBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]], let status = attachments.first?[.status] as? Int,
           status != SCFrameStatus.complete.rawValue { return }

        let ready = delivering.withLock { pending in
            if pending { return false }
            pending = true
            return true
        }
        guard ready else { return }
        let done: @Sendable () -> Void = { [delivering] in delivering.withLock { $0 = false } }
        let settings = effects.withLock { $0 }
        // Without effects the captured surface goes to the layer as is: no GPU readback or copy.
        let frame = settings.lut == nil && settings.sharpness <= 0 ? wrap(pixels) : render(pixels, settings)
        if let frame { deliver(frame, done) } else { done() }
    }

    private func wrap(_ buffer: CVPixelBuffer) -> PreviewFrame? {
        CVPixelBufferGetIOSurface(buffer).map { PreviewFrame(buffer: buffer, surface: $0.takeUnretainedValue()) }
    }

    /// Applies effects on the GPU straight into an IOSurface-backed buffer.
    private func render(_ pixels: CVPixelBuffer, _ settings: Effects) -> PreviewFrame? {
        let source = CIImage(cvPixelBuffer: pixels)
        var image = source
        if let lut = settings.lut {
            image = image.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": lut.size, "inputCubeData": lut.data
            ])
        }
        if settings.sharpness > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: settings.sharpness])
        }
        guard let output = makeBuffer(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        else { return nil }
        CVBufferPropagateAttachments(pixels, output)
        let destination = CIRenderDestination(pixelBuffer: output)
        destination.colorSpace = source.colorSpace
        guard (try? context.startTask(toRender: image.cropped(to: source.extent), to: destination)
            .waitUntilCompleted()) != nil else { return nil }
        return wrap(output)
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let size = CGSize(width: width, height: height)
        if pool == nil || poolSize != size {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                kCVPixelBufferMetalCompatibilityKey: true
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
            pool = created
            poolSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}

@MainActor
final class LivePreview: NSObject, NSWindowDelegate {
    private let picker = SCContentSharingPicker.shared
    private let errorHandler: (String) -> Void
    private let queue = DispatchQueue(label: "com.evgeniyov.bestdisplay.preview", qos: .userInitiated)
    private var stream: SCStream?
    private var frames: PreviewFrames?
    private var panel: NSWindow?
    /// The layer-backed view that shows frames; exists while the panel is open.
    private var video: NSView?
    /// The last delivered frame, also shown when the panel opens after the first frame.
    private var latest: PreviewFrame?
    private var lutButton: NSButton?
    private var session = UUID()
    private var observing = false

    init(errorHandler: @escaping (String) -> Void) {
        self.errorHandler = errorHandler
    }

    func chooseSource() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        if !observing {
            picker.add(self)
            observing = true
        }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
        configuration.allowsChangingSelectedContent = false
        if let identifier = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [identifier] }
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.isActive = true
        picker.present()
    }

    func start(with filter: SCContentFilter) async {
        guard stream == nil else { return }
        let configuration = SCStreamConfiguration()
        let bounds = filter.contentRect
        let factor = min(1, 1120 / max(1, bounds.width), 800 / max(1, bounds.height))
        configuration.width = max(2, Int(bounds.width * factor))
        configuration.height = max(2, Int(bounds.height * factor))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 24)
        configuration.queueDepth = 3
        configuration.capturesAudio = false
        configuration.showsCursor = false

        let token = UUID()
        session = token
        let frames = PreviewFrames { [weak self] frame, completed in
            Task { @MainActor [weak self] in
                defer { completed() }
                guard let self, self.session == token else { return }
                self.latest = frame
                self.video?.layer?.contents = frame.surface
            }
        }
        let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try capture.addStreamOutput(frames, type: .screen, sampleHandlerQueue: queue)
            stream = capture
            self.frames = frames
            try await capture.startCapture()
            if stream === capture { showPanel() }
        } catch {
            if stream == nil || stream === capture {
                stop()
                errorHandler(error.localizedDescription)
            }
        }
    }

    func stop() {
        session = UUID()
        picker.isActive = false
        if observing {
            picker.remove(self)
            observing = false
        }
        if let stream {
            self.stream = nil
            Task { try? await stream.stopCapture() }
        }
        frames = nil
        panel?.orderOut(nil)
        panel = nil
        video = nil
        latest = nil
        lutButton = nil
    }

    private func showPanel() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 400),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Картинка в картинке"
        window.minSize = CGSize(width: 360, height: 220)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.fullScreenPrimary]
        window.sharingType = .none
        window.delegate = self

        let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(sharpnessChanged(_:)))
        slider.setAccessibilityLabel("Резкость")
        slider.toolTip = "Подчеркни границы деталей в окне просмотра."
        let lut = NSButton(title: "Выбрать LUT…", target: self, action: #selector(chooseLUT))
        lut.toolTip = "Примени таблицу цветов из файла .cube к окну просмотра."
        lutButton = lut
        let fullScreen = NSButton(title: "Полноэкранный режим", target: self, action: #selector(toggleFullScreen))
        fullScreen.toolTip = "Разверни окно просмотра на весь дисплей или верни прежний размер."
        let bar = NSStackView(views: [NSTextField(labelWithString: "Резкость"), slider, lut, fullScreen])
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        let image = NSView()
        image.wantsLayer = true
        image.layerContentsRedrawPolicy = .never
        image.layer?.backgroundColor = NSColor.black.cgColor
        image.layer?.contentsGravity = .resizeAspect
        image.layer?.contents = latest?.surface
        video = image
        let content = NSView()
        window.contentView = content
        for child in [image, bar] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: content.trailingAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            image.topAnchor.constraint(equalTo: bar.bottomAnchor),
            image.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window.center()
        panel = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func sharpnessChanged(_ sender: NSSlider) {
        let value = sender.doubleValue
        frames?.effects.withLock { $0.sharpness = value }
    }

    @objc private func toggleFullScreen() { panel?.toggleFullScreen(nil) }

    @objc private func chooseLUT() {
        guard let frames, let panel else { return }
        if frames.effects.withLock({ $0.lut != nil }) {
            frames.effects.withLock { $0.lut = nil }
            lutButton?.title = "Выбрать LUT…"
            lutButton?.toolTip = "Примени таблицу цветов из файла .cube к окну просмотра."
            return
        }
        let dialog = NSOpenPanel()
        dialog.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText]
        dialog.canChooseDirectories = false
        dialog.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = dialog.url, let self, self.frames === frames else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard (1...12_000_000).contains(size) else { throw DisplayFailure("Выбери непустой файл LUT размером до 12 МБ.") }
                let lut = try CubeLUT(contents: String(contentsOf: url, encoding: .utf8))
                frames.effects.withLock { $0.lut = lut }
                self.lutButton?.title = "Убрать LUT"
                self.lutButton?.toolTip = "Убери таблицу цветов из окна просмотра."
            } catch {
                let alert = NSAlert(error: error)
                alert.beginSheetModal(for: panel)
            }
        }
    }

    func windowWillClose(_ notification: Notification) { stop() }
}

extension LivePreview: SCContentSharingPickerObserver, SCStreamDelegate {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            if self?.stream == nil { self?.stop() }
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?
    ) {
        guard stream == nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.observing else { return }
            await self.start(with: filter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let text = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.stop()
            self?.errorHandler(text)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let text = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.stop()
            self.errorHandler(text)
        }
    }
}
