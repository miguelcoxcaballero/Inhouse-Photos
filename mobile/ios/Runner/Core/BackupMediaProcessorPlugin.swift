import AVFoundation
import Flutter
import ImageIO
import UniformTypeIdentifiers

/// Creates disposable Storage saver copies while leaving the Photos library untouched.
final class BackupMediaProcessorPlugin: ImmichPlugin, FlutterPlugin {
  static let name = "BackupMediaProcessorPlugin"

  private static let channelName = "com.inhousesoftware.photos/backup_media"
  private static let maxPhotoPixels = 16_000_000.0
  private static let staleFileAge: TimeInterval = 24 * 60 * 60

  private var channel: FlutterMethodChannel?
  private let exportLock = NSLock()
  private var activeExports: [String: AVAssetExportSession] = [:]
  private var progressTimers: [String: DispatchSourceTimer] = [:]

  static func register(with registrar: any FlutterPluginRegistrar) {
    let instance = BackupMediaProcessorPlugin()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.publish(instance)
    instance.cleanupStaleFiles()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "cancel" {
      guard
        let arguments = call.arguments as? [String: Any],
        let operationId = arguments["operationId"] as? String,
        !operationId.isEmpty
      else {
        result(FlutterError(code: "invalid_arguments", message: "operationId is required", details: nil))
        return
      }
      cancelExport(operationId)
      result(nil)
      return
    }

    guard call.method == "prepare" else {
      result(FlutterMethodNotImplemented)
      return
    }

    guard
      let arguments = call.arguments as? [String: Any],
      let sourcePath = arguments["sourcePath"] as? String,
      let originalFileName = arguments["originalFileName"] as? String,
      let operationId = arguments["operationId"] as? String,
      !sourcePath.isEmpty,
      !originalFileName.isEmpty,
      !operationId.isEmpty
    else {
      result(FlutterError(code: "invalid_arguments", message: "sourcePath, originalFileName and operationId are required", details: nil))
      return
    }

    let source = URL(fileURLWithPath: sourcePath)
    guard FileManager.default.fileExists(atPath: source.path) else {
      result(FlutterError(code: "missing_source", message: "The media source does not exist", details: nil))
      return
    }

    emitProgress(operationId, 0.02)
    if arguments["isVideo"] as? Bool == true {
      prepareVideo(source: source, originalFileName: originalFileName, operationId: operationId, result: result)
    } else {
      preparePhoto(source: source, originalFileName: originalFileName, operationId: operationId, result: result)
    }
  }

  override func detachFromEngine() {
    super.detachFromEngine()
    channel?.setMethodCallHandler(nil)
    channel = nil

    exportLock.lock()
    let exports = Array(activeExports.values)
    let timers = Array(progressTimers.values)
    activeExports.removeAll()
    progressTimers.removeAll()
    exportLock.unlock()

    timers.forEach { $0.cancel() }
    exports.forEach { $0.cancelExport() }
  }

  private func preparePhoto(
    source: URL,
    originalFileName: String,
    operationId: String,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      guard !self.detached else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
        self.finishWithOriginal(operationId: operationId, result: result)
        return
      }

      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
      let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
      let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
      guard width > 0, height > 0 else {
        self.finishWithOriginal(operationId: operationId, result: result)
        return
      }

      self.emitProgress(operationId, 0.18)
      let scale = min(1, sqrt(Self.maxPhotoPixels / (width * height)))
      let maxDimension = max(1, Int(ceil(max(width, height) * scale)))
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
        self.finishWithOriginal(operationId: operationId, result: result)
        return
      }

      self.emitProgress(operationId, 0.58)
      let preservesAlpha = Self.hasAlpha(image)
      let fileExtension = preservesAlpha ? "png" : "jpg"
      guard let output = self.newOutputFile(fileExtension: fileExtension) else {
        self.finishWithOriginal(operationId: operationId, result: result)
        return
      }

      let type = preservesAlpha ? UTType.png.identifier : UTType.jpeg.identifier
      guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil) else {
        self.removeIfPresent(output)
        self.finishWithOriginal(operationId: operationId, result: result)
        return
      }

      var outputProperties = properties ?? [:]
      outputProperties[kCGImagePropertyOrientation] = 1
      outputProperties[kCGImagePropertyPixelWidth] = image.width
      outputProperties[kCGImagePropertyPixelHeight] = image.height
      if !preservesAlpha {
        outputProperties[kCGImageDestinationLossyCompressionQuality] = 0.88
      }
      CGImageDestinationAddImage(destination, image, outputProperties as CFDictionary)
      guard CGImageDestinationFinalize(destination) else {
        self.removeIfPresent(output)
        self.finishWithOriginal(operationId: operationId, result: result)
        return
      }

      self.emitProgress(operationId, 0.96)
      self.finishPrepared(
        source: source,
        output: output,
        fileName: Self.replacingExtension(originalFileName, with: fileExtension),
        operationId: operationId,
        result: result
      )
    }
  }

  private func prepareVideo(
    source: URL,
    originalFileName: String,
    operationId: String,
    result: @escaping FlutterResult
  ) {
    let asset = AVURLAsset(url: source)
    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080),
          exporter.supportedFileTypes.contains(.mp4),
          let output = newOutputFile(fileExtension: "mp4")
    else {
      finishWithOriginal(operationId: operationId, result: result)
      return
    }

    exporter.outputURL = output
    exporter.outputFileType = .mp4
    exporter.shouldOptimizeForNetworkUse = true

    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now(), repeating: .milliseconds(200))
    timer.setEventHandler { [weak self, weak exporter] in
      guard let self, let exporter else { return }
      self.emitProgress(operationId, 0.02 + Double(exporter.progress) * 0.94)
    }

    exportLock.lock()
    activeExports[operationId] = exporter
    progressTimers[operationId] = timer
    exportLock.unlock()
    timer.resume()

    exporter.exportAsynchronously { [weak self, weak exporter] in
      guard let self, let exporter else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      self.removeExport(operationId)
      switch exporter.status {
      case .completed:
        self.emitProgress(operationId, 0.98)
        self.finishPrepared(
          source: source,
          output: output,
          fileName: Self.replacingExtension(originalFileName, with: "mp4"),
          operationId: operationId,
          result: result
        )
      case .failed, .cancelled:
        self.removeIfPresent(output)
        self.finishWithOriginal(operationId: operationId, result: result)
      default:
        self.removeIfPresent(output)
        self.finishWithOriginal(operationId: operationId, result: result)
      }
    }
  }

  private func finishPrepared(
    source: URL,
    output: URL,
    fileName: String,
    operationId: String,
    result: @escaping FlutterResult
  ) {
    let sourceSize = fileSize(source)
    let outputSize = fileSize(output)
    guard outputSize > 0, sourceSize > outputSize else {
      removeIfPresent(output)
      finishWithOriginal(operationId: operationId, result: result)
      return
    }

    emitProgress(operationId, 1)
    completeOnMain(result, ["path": output.path, "fileName": fileName])
  }

  private func finishWithOriginal(operationId: String, result: @escaping FlutterResult) {
    emitProgress(operationId, 1)
    completeOnMain(result, nil)
  }

  private func emitProgress(_ operationId: String, _ progress: Double) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.detached else { return }
      self.channel?.invokeMethod(
        "progress",
        arguments: ["operationId": operationId, "progress": min(1, max(0, progress))]
      )
    }
  }

  private func completeOnMain(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.detached else { return }
      result(value)
    }
  }

  private func removeExport(_ operationId: String) {
    exportLock.lock()
    activeExports.removeValue(forKey: operationId)
    let timer = progressTimers.removeValue(forKey: operationId)
    exportLock.unlock()
    timer?.cancel()
  }

  private func cancelExport(_ operationId: String) {
    exportLock.lock()
    let exporter = activeExports.removeValue(forKey: operationId)
    let timer = progressTimers.removeValue(forKey: operationId)
    exportLock.unlock()
    timer?.cancel()
    exporter?.cancelExport()
  }

  private func newOutputFile(fileExtension: String) -> URL? {
    guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
    let directory = cache.appendingPathComponent("storage-saver", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
    } catch {
      return nil
    }
  }

  private func cleanupStaleFiles() {
    DispatchQueue.global(qos: .utility).async {
      guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
      let directory = cache.appendingPathComponent("storage-saver", isDirectory: true)
      let cutoff = Date().addingTimeInterval(-Self.staleFileAge)
      guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      ) else { return }
      for file in files {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if modified < cutoff {
          try? FileManager.default.removeItem(at: file)
        }
      }
    }
  }

  private func fileSize(_ url: URL) -> Int64 {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
  }

  private func removeIfPresent(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private static func replacingExtension(_ fileName: String, with fileExtension: String) -> String {
    let stem = (fileName as NSString).deletingPathExtension
    return "\(stem).\(fileExtension)"
  }

  private static func hasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .first, .last, .premultipliedFirst, .premultipliedLast:
      return true
    default:
      return false
    }
  }
}
