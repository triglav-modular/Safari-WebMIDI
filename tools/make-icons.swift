import AppKit
import PDFKit

// Icons from icon.ai (a PDF-compatible Illustrator file):
//   glyph PNGs    the glyph alone, for Safari's toolbar: as its own buttons
//                 in light and dark, and grey, which Safari draws in the
//                 accent colour, while a tab uses Web MIDI
//   tile PNGs     the glyph in white on a black macOS-style rounded square,
//                 for Safari's list of extensions and for the .icns fallback
//   AppIcon.icon  an Icon Composer icon: black fill, the white glyph as a
//                 glass layer, for the app on macOS 26 and later
//   swift tools/make-icons.swift icon.ai <out dir>
let args = CommandLine.arguments
let doc = PDFDocument(url: URL(fileURLWithPath: args[1]))!
let page = doc.page(at: 0)!
let box = page.bounds(for: .mediaBox)
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ size: Int, _ draw: (CGContext, CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    draw(ctx.cgContext, CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
func glyph(_ cg: CGContext, in rect: CGRect, white: Bool = false, color: CGColor? = nil) {
    cg.saveGState()
    if white { cg.beginTransparencyLayer(auxiliaryInfo: nil) }
    let scale = min(rect.width / box.width, rect.height / box.height)
    cg.translateBy(x: rect.midX - box.width * scale / 2, y: rect.midY - box.height * scale / 2)
    cg.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: cg)
    if white {
        // Keep the glyph's coverage, change its colour.
        cg.setBlendMode(.sourceIn)
        cg.setFillColor(color ?? glyphWhite)
        cg.fill(CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height))
        cg.endTransparencyLayer()
    }
    cg.restoreGState()
}
// macOS icon grid: an 824-unit body on a 1024 canvas, corner radius 185.4.
func tile(_ cg: CGContext, _ s: CGFloat) {
    let body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let path = CGPath(roundedRect: body, cornerWidth: s * 185.4 / 1024, cornerHeight: s * 185.4 / 1024, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 20 / 1024,
                 color: CGColor(gray: 0, alpha: 0.3))
    cg.addPath(path); cg.setFillColor(CGColor(gray: 0, alpha: 1)); cg.fillPath()
    cg.restoreGState()
    glyph(cg, in: body.insetBy(dx: body.width * 0.19, dy: body.height * 0.19), white: true)
}
// The glyph's white.  Pure white on black is all grey, and Safari draws an
// all-grey extension icon as a template: tinted flat, a blank tile in its
// settings (measured with Safari's own safari_isGrayscale: #FFFAF0 still
// counts as grey, #FFF5E1 does not).  This white is the least colour that
// escapes it, and still reads as white on black.
let glyphWhite = CGColor(srgbRed: 1, green: 245.0 / 255, blue: 225.0 / 255, alpha: 1)
func write(_ name: String, _ data: Data) { try! data.write(to: out.appendingPathComponent(name)) }

// The toolbar button.  Safari 27 draws a grey icon (above) in the accent
// colour wherever the extension may read the page, which for this one is
// every page, and in labelColor, as its own buttons, only where it may
// not; an icon in colour it draws as it is (-[ExtensionButton setImage:],
// -[WebExtensionToolbarItem updateExtensionIconForBrowserWindowController:]).
// So the glyph in grey, toolbar-N, is the accent, for a tab whose page is
// using Web MIDI (background.js).  The button otherwise is labelColor
// itself, black or white at 85%, for light and dark (the manifest's
// icon_variants), with just enough blue taken from or added to it to count
// as colour.  Measured on this glyph with safari_isGrayscale, which
// averages the image down first: 28 levels of blue passed for grey at 85%,
// 32 did not.
let toolbarBlue: CGFloat = 36.0 / 255
for s in [16, 19, 32, 38, 48, 64] {
    let r = CGRect(x: 0, y: 0, width: s, height: s)
    write("toolbar-\(s).png", render(s) { cg, _ in glyph(cg, in: r, white: true, color: CGColor(gray: 0, alpha: 1)) })
    write("toolbar-light-\(s).png", render(s) { cg, _ in
        glyph(cg, in: r, white: true, color: CGColor(srgbRed: 0, green: 0, blue: toolbarBlue, alpha: 0.85))
    })
    write("toolbar-dark-\(s).png", render(s) { cg, _ in
        glyph(cg, in: r, white: true, color: CGColor(srgbRed: 1, green: 1, blue: 1 - toolbarBlue, alpha: 0.85))
    })
}
for s in [48, 64, 96, 128, 256, 512] { write("icon-\(s).png", render(s, tile)) }
// The touch icon: black to the edges and square; iOS rounds it itself.
func flat(_ rounded: Bool) -> (CGContext, CGFloat) -> Void {
    return { cg, s in
        let r = CGRect(x: 0, y: 0, width: s, height: s)
        if rounded { cg.addPath(CGPath(roundedRect: r, cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil)) }
        else { cg.addRect(r) }
        cg.setFillColor(CGColor(gray: 0, alpha: 1)); cg.fillPath()
        glyph(cg, in: r.insetBy(dx: s * 0.14, dy: s * 0.14), white: true)
    }
}
// The tab favicon matches Triglav Modular's: its grainy black square
// (favicon-background.png, the background layers of Triglav_Modular_Designs/
// triglav_modular_favicon.psd) with the glyph in pure white over the same
// box as Triglav's glyph, 59-453 of 512.  Safari's tab bar (27) backs a
// favicon with a plate of its own: white in dark mode when the icon's key
// colour is dark and holds over half of it; black in light mode when every
// edge is light.  A flat black square takes the white plate.  This grain and
// gradient keep any one colour under half of it, so neither plate comes.
// The page links favicon.ico, which holds it at 16 and 32 px.
let faviconBackground = NSImage(contentsOf: URL(fileURLWithPath: args[1]).deletingLastPathComponent()
    .appendingPathComponent("favicon-background.png"))!
func favicon(_ cg: CGContext, _ s: CGFloat) {
    let r = CGRect(x: 0, y: 0, width: s, height: s)
    NSGraphicsContext.current!.imageInterpolation = .high
    faviconBackground.draw(in: r)
    glyph(cg, in: r.insetBy(dx: s * 59 / 512, dy: s * 59 / 512), white: true, color: CGColor(gray: 1, alpha: 1))
}
for s in [16, 32, 96] { write("favicon-\(s).png", render(s, favicon)) }
// Safari keeps a page's favicon for seven days.  Before then it takes a new
// one only if it has several sizes, one exactly 32 px, and the old one had
// one size; a single-size replacement is rejected, and that rejection blocks
// every new icon for the page for another seven days.  Hence an .ico.
let ico = NSMutableData()
let dest = CGImageDestinationCreateWithData(ico, "com.microsoft.ico" as CFString, 2, nil)!
for s in [16, 32] {
    CGImageDestinationAddImageFromSource(dest, CGImageSourceCreateWithData(render(s, favicon) as CFData, nil)!, 0, nil)
}
precondition(CGImageDestinationFinalize(dest))
write("favicon.ico", ico as Data)
write("apple-touch-icon.png", render(180, flat(false)))
let set = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (s, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                  (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    try! render(s, tile).write(to: set.appendingPathComponent("icon_\(name).png"))
}

// The Icon Composer icon.  The glyph layer fills the 1024-point canvas with
// the glyph in the middle at the same proportion as the tile.
let icon = out.appendingPathComponent("AppIcon.icon")
try? FileManager.default.createDirectory(at: icon.appendingPathComponent("Assets"), withIntermediateDirectories: true)
try! render(1024) { cg, s in
    let side = s * 824 / 1024 * 0.72
    glyph(cg, in: CGRect(x: (s - side) / 2, y: (s - side) / 2, width: side, height: side), white: true)
}.write(to: icon.appendingPathComponent("Assets/glyph.png"))
let json = """
{
  "fill" : {
    "solid" : "srgb:0.00000,0.00000,0.00000,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        {
          "glass" : true,
          "image-name" : "glyph.png",
          "name" : "glyph"
        }
      ],
      "lighting" : "individual",
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "specular" : true,
      "translucency" : {
        "enabled" : true,
        "value" : 0.4
      }
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}
"""
try! json.write(to: icon.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
