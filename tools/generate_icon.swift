// generate_icon.swift — renders the app icon (1024×1024 PNG) with
// CoreGraphics: matte black, aperture blade ring, red dot (the Leica nod),
// "M10" in Helvetica. Run:  swift tools/generate_icon.swift
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

let s = CGFloat(size)

// background: near-black with a subtle vertical shade
let bgColors = [
    CGColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1),
    CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1),
] as CFArray
let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    colors: bgColors, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s),
                       end: CGPoint(x: 0, y: 0), options: [])

// aperture ring: 10 blades as arcs
let center = CGPoint(x: s * 0.5, y: s * 0.56)
let outerR = s * 0.30
let innerR = s * 0.185
ctx.saveGState()
for i in 0..<10 {
    let a0 = CGFloat(i) / 10 * .pi * 2
    let a1 = a0 + .pi * 2 / 10 * 0.72
    ctx.addArc(center: center, radius: outerR, startAngle: a0, endAngle: a1, clockwise: false)
    ctx.addArc(center: center, radius: innerR, startAngle: a1, endAngle: a0, clockwise: true)
    ctx.closePath()
    ctx.setFillColor(CGColor(red: 0.82, green: 0.82, blue: 0.83, alpha: 1))
    ctx.fillPath()
}
// darken the ring toward the center for depth
ctx.restoreGState()

// center: open circle (black) + red dot
ctx.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.045, alpha: 1))
ctx.fillEllipse(in: CGRect(x: center.x - innerR * 0.98, y: center.y - innerR * 0.98,
                           width: innerR * 1.96, height: innerR * 1.96))
let dotR = s * 0.045
ctx.setFillColor(CGColor(red: 0.79, green: 0.10, blue: 0.12, alpha: 1)) // leica red
ctx.fillEllipse(in: CGRect(x: center.x - dotR, y: center.y - dotR,
                           width: dotR * 2, height: dotR * 2))

// "M10" wordmark
let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, s * 0.135, nil)
let attrs: [CFString: Any] = [
    kCTFontAttributeName: font,
    kCTForegroundColorAttributeName: CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1),
]
let attrString = CFAttributedStringCreate(nil, "M10" as CFString, attrs as CFDictionary)!
let line = CTLineCreateWithAttributedString(attrString)
let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
ctx.textPosition = CGPoint(x: (s - lineBounds.width) / 2, y: s * 0.115)
CTLineDraw(line, ctx)

let image = ctx.makeImage()!
let outURL = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon_1024.png")
let dest = CGImageDestinationCreateWithURL(outURL as CFURL,
                                          UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outURL.path)")
