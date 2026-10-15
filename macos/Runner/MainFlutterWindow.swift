import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var mediaChannel: FlutterMethodChannel?

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

    channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
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
