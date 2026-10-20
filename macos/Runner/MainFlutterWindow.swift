import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSDraggingSource {
  private var mediaChannel: FlutterMethodChannel?

  /// The last press or drag of the mouse, which a drag of files out of the
  /// window has to start from.
  private var lastMouseEvent: NSEvent?
  private var mouseMonitor: Any?

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    return context == .outsideApplication ? [.copy, .link, .generic] : []
  }

  /// Drag [paths] out of the window, as the files themselves.
  private func dragFiles(_ paths: [String]) -> Bool {
    guard let view = self.contentViewController?.view,
          let event = lastMouseEvent ?? NSApp.currentEvent else { return false }
    let at = view.convert(event.locationInWindow, from: nil)
    var items: [NSDraggingItem] = []
    for (i, path) in paths.enumerated() where FileManager.default.fileExists(atPath: path) {
      let url = NSURL(fileURLWithPath: path)
      let item = NSDraggingItem(pasteboardWriter: url)
      let icon = NSWorkspace.shared.icon(forFile: path)
      icon.size = NSSize(width: 64, height: 64)
      let offset = CGFloat(min(i, 4) * 6)
      item.setDraggingFrame(NSRect(x: at.x - 32 + offset, y: at.y - 32 - offset, width: 64, height: 64), contents: icon)
      items.append(item)
    }
    if items.isEmpty { return false }
    view.beginDraggingSession(with: items, event: event, source: self)
    return true
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    let defaultSize = NSSize(width: 1440, height: 900)
    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: defaultSize)
    let x = screenFrame.origin.x + (screenFrame.width - defaultSize.width) / 2
    let y = screenFrame.origin.y + (screenFrame.height - defaultSize.height) / 2
    self.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: defaultSize), display: true)
    self.title = "GenerativeView"

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "generativeview/media",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    self.mediaChannel = channel

    mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
      self?.lastMouseEvent = event
      return event
    }

    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "copyFiles":
        guard let args = call.arguments as? [String: Any],
              let paths = args["paths"] as? [String], !paths.isEmpty else {
          result(false)
          return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        result(pb.writeObjects(paths.map { NSURL(fileURLWithPath: $0) }))

      case "dragFiles":
        guard let args = call.arguments as? [String: Any],
              let paths = args["paths"] as? [String] else {
          result(false)
          return
        }
        result(self?.dragFiles(paths) ?? false)

      case "copyFile":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(false)
          return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.writeObjects([NSURL(fileURLWithPath: path)])
        result(ok)

      case "readCopiedFile":
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = urls.first {
          if let data = try? Data(contentsOf: first) {
            result(FlutterStandardTypedData(bytes: data))
            return
          }
        }
        if let pngData = pb.data(forType: .png) {
          result(FlutterStandardTypedData(bytes: pngData))
          return
        }
        if let tiffData = pb.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
          result(FlutterStandardTypedData(bytes: pngData))
          return
        }
        result(nil)

      case "pasteSource":
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = urls.first {
          result(["path": first.path])
          return
        }
        if let pngData = pb.data(forType: .png) {
          result([
            "bytes": FlutterStandardTypedData(bytes: pngData),
            "type": "image/png"
          ])
          return
        }
        if let tiffData = pb.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
          result([
            "bytes": FlutterStandardTypedData(bytes: pngData),
            "type": "image/png"
          ])
          return
        }
        result(nil)

      case "trashFile":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result("failed: no path")
          return
        }
        do {
          try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
          result("trashed")
        } catch {
          result("failed: \(error.localizedDescription)")
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
