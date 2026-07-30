import Foundation

/// An import asked for on the command line rather than through the picker.
///
/// The measurement this route lives or dies by - what a full-resolution design
/// costs the widget extension - cannot be taken by tapping through a sheet: the
/// footprint has to be read out of a render the process makes on its own, and a
/// sweep across frame counts and layouts is dozens of runs. So the same importer
/// the picker calls is reachable from a launch argument, and the only part not
/// covered by a headless run is `PHPickerViewController` handing over a URL.
struct RuntimeImportRequest: Equatable, Sendable {
    /// A file the app can read directly. The sweep points this at a clip pushed
    /// into the simulator beforehand.
    var path: String?
    /// A clip in the app's own bundle, by resource name with extension. Lets a
    /// run happen with nothing staged at all.
    var bundledResource: String?
    var options = RuntimeDesignImporter.Options()
    /// Archives every existing runtime-frame design first, so a sweep measures
    /// the design it just made rather than whichever one an earlier run left
    /// selected.
    var replacesExisting = false

    static func parse(_ arguments: [String]) -> RuntimeImportRequest? {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.index(after: index) < arguments.endIndex
            else { return nil }
            let next = arguments[arguments.index(after: index)]
            // A flag whose value is missing takes the following flag as its
            // value otherwise, which silently imports a file called
            // "-MotionaryImportFPS".
            return next.hasPrefix("-Motionary") ? nil : next
        }

        let path = value("-MotionaryImportPath")
        let resource = value("-MotionaryImportBundled")
        guard path != nil || resource != nil else { return nil }

        var request = RuntimeImportRequest(path: path, bundledResource: resource)
        if let rate = value("-MotionaryImportFPS").flatMap(Int.init) {
            request.options.framesPerSecond = BlinkCycle.clampedFramesPerSecond(rate)
        }
        if let layout = value("-MotionaryImportLayout")
            .flatMap(RuntimeFrameSequence.Layout.init(rawValue:)) {
            request.options.layout = layout
        }
        if let quality = value("-MotionaryImportQuality").flatMap(Double.init), quality > 0, quality <= 1 {
            request.options.quality = quality
        }
        request.replacesExisting = arguments.contains("-MotionaryImportReplace")
        return request
    }

    /// Where the clip actually is, given a bundle to look in.
    func resolveSource(in bundle: Bundle) -> URL? {
        if let path { return URL(fileURLWithPath: path) }
        guard let bundledResource else { return nil }
        let name = (bundledResource as NSString).deletingPathExtension
        let ext = (bundledResource as NSString).pathExtension
        return bundle.url(forResource: name, withExtension: ext.isEmpty ? nil : ext)
    }
}
