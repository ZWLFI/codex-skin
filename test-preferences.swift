import AppKit

@main
struct PreferencesTest {
    @MainActor static func main() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("skin-preview-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        func writeImage(red: UInt8, blue: UInt8) throws {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let pixel = bitmap.bitmapData!
            pixel[0] = red; pixel[1] = 0; pixel[2] = blue; pixel[3] = 255
            try bitmap.representation(using: .png, properties: [:])!.write(to: file)
        }
        try writeImage(red: 255, blue: 0)
        let model = SkinPreferencesModel()
        model.settings = BackgroundSettings(imagePath: file.path, opacity: 0.42, layout: .tile)
        let first = model.image!.tiffRepresentation!
        try writeImage(red: 0, blue: 255)
        model.reloadPreview()
        precondition(first != model.image!.tiffRepresentation!, "Replacing a file must refresh the preview")
        var changes = 0
        model.onChange = { _ in changes += 1 }
        model.preset(2)
        precondition(model.settings.hideRail && model.settings.hideTopBar && model.settings.contentScale == 1.5)
        model.preset(1)
        precondition(!model.settings.hideRail && !model.settings.hideTopBar && model.settings.railScale == 0.7)
        model.preset(0)
        precondition(model.settings.railScale == 1 && model.settings.topScale == 1 && model.settings.contentScale == 1)
        precondition(model.settings.imagePath == file.path && model.settings.opacity == 0.42 && model.settings.layout == .tile)
        precondition(changes == 3)
        print("preferences test passed: same-path preview refresh, presets, retained background, change callbacks")
    }
}
