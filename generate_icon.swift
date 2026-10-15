import Cocoa
import CoreGraphics

func renderIconImage(pixelSize: Int) -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Failed to create CGContext")
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let scale = CGFloat(pixelSize) / 1024.0
    ctx.scaleBy(x: scale, y: scale)

    func addRoundedRect(_ context: CGContext, rect: CGRect, radius: CGFloat) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
    }

    // 1. Outer macOS Squircle Base with Drop Shadow
    let iconRect = CGRect(x: 92, y: 92, width: 840, height: 840)
    let cornerRadius: CGFloat = 190

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * scale), blur: 36 * scale, color: CGColor(red: 0.35, green: 0.02, blue: 0.08, alpha: 0.42))
    addRoundedRect(ctx, rect: iconRect, radius: cornerRadius)
    ctx.setFillColor(CGColor(red: 0.65, green: 0.06, blue: 0.16, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to main squircle
    ctx.saveGState()
    addRoundedRect(ctx, rect: iconRect, radius: cornerRadius)
    ctx.clip()

    // Main Ruby -> Crimson -> Warm Coral Diagonal Gradient
    let bgColors = [
        CGColor(red: 0.48, green: 0.03, blue: 0.14, alpha: 1.0),
        CGColor(red: 0.82, green: 0.12, blue: 0.22, alpha: 1.0),
        CGColor(red: 0.98, green: 0.43, blue: 0.32, alpha: 1.0)
    ] as CFArray
    let bgLocations: [CGFloat] = [0.0, 0.55, 1.0]
    if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations) {
        ctx.drawLinearGradient(
            bgGradient,
            start: CGPoint(x: iconRect.minX, y: iconRect.minY),
            end: CGPoint(x: iconRect.maxX, y: iconRect.maxY),
            options: []
        )
    }

    // Ambient inner glow at top-right
    let glowColors = [
        CGColor(red: 1.0, green: 0.72, blue: 0.58, alpha: 0.45),
        CGColor(red: 1.0, green: 0.35, blue: 0.28, alpha: 0.0)
    ] as CFArray
    if let radialGlow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            radialGlow,
            startCenter: CGPoint(x: 760, y: 780),
            startRadius: 10,
            endCenter: CGPoint(x: 720, y: 740),
            endRadius: 460,
            options: []
        )
    }

    // 2. Tilted Frosted Backing Sheet
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 512)
    ctx.rotate(by: -0.14)
    let backSheetRect = CGRect(x: -265, y: -235, width: 530, height: 470)
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale, color: CGColor(red: 0.25, green: 0.0, blue: 0.05, alpha: 0.30))
    let backSheetPath = CGPath(roundedRect: backSheetRect, cornerWidth: 28, cornerHeight: 28, transform: nil)
    ctx.addPath(backSheetPath)
    ctx.setFillColor(CGColor(red: 1.0, green: 0.94, blue: 0.94, alpha: 0.26))
    ctx.fillPath()
    ctx.addPath(backSheetPath)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.48))
    ctx.setLineWidth(3.0)
    ctx.strokePath()
    ctx.restoreGState()

    // 3. Foreground Split-Screen Dual Frosted Pages
    let leftPaneRect = CGRect(x: 222, y: 268, width: 282, height: 488)
    let rightPaneRect = CGRect(x: 520, y: 268, width: 282, height: 488)

    func drawFrostedPane(rect: CGRect, foldedTopRight: Bool) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 28 * scale, color: CGColor(red: 0.22, green: 0.0, blue: 0.04, alpha: 0.35))

        let r: CGFloat = 26
        let foldSize: CGFloat = foldedTopRight ? 68 : 0
        let path = CGMutablePath()

        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)

        if foldedTopRight {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - foldSize))
            path.addLine(to: CGPoint(x: rect.maxX - foldSize, y: rect.maxY))
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        }

        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        path.closeSubpath()

        ctx.addPath(path)
        ctx.clip()

        let paneColors = [
            CGColor(red: 1.0, green: 0.96, blue: 0.96, alpha: 0.86),
            CGColor(red: 0.98, green: 0.88, blue: 0.89, alpha: 0.72)
        ] as CFArray
        if let paneGrad = CGGradient(colorsSpace: colorSpace, colors: paneColors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(
                paneGrad,
                start: CGPoint(x: rect.minX, y: rect.maxY),
                end: CGPoint(x: rect.maxX, y: rect.minY),
                options: []
            )
        }

        ctx.setFillColor(CGColor(red: 0.78, green: 0.16, blue: 0.24, alpha: 0.14))
        for i in 0..<5 {
            let lineY = rect.maxY - 96 - CGFloat(i) * 64
            let lineW: CGFloat = (i == 0) ? 120 : (i == 4 ? 140 : 196)
            let bar = CGRect(x: rect.minX + 38, y: lineY, width: lineW, height: 14)
            let barPath = CGPath(roundedRect: bar, cornerWidth: 7, cornerHeight: 7, transform: nil)
            ctx.addPath(barPath)
            ctx.fillPath()
        }

        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.82))
        ctx.setLineWidth(3.5)
        ctx.strokePath()

        if foldedTopRight {
            let flap = CGMutablePath()
            flap.move(to: CGPoint(x: rect.maxX - foldSize, y: rect.maxY))
            flap.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - foldSize))
            flap.addLine(to: CGPoint(x: rect.maxX - foldSize + 14, y: rect.maxY - foldSize))
            flap.addArc(
                tangent1End: CGPoint(x: rect.maxX - foldSize, y: rect.maxY - foldSize),
                tangent2End: CGPoint(x: rect.maxX - foldSize, y: rect.maxY - foldSize + 14),
                radius: 14
            )
            flap.closeSubpath()
            ctx.addPath(flap)
            ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.92))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    drawFrostedPane(rect: leftPaneRect, foldedTopRight: false)
    drawFrostedPane(rect: rightPaneRect, foldedTopRight: true)

    // 4. Glowing Optical Zoom Loupe Ring
    ctx.saveGState()
    let loupeCenter = CGPoint(x: 512, y: 500)
    let loupeRadius: CGFloat = 198
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 22 * scale, color: CGColor(red: 1.0, green: 0.55, blue: 0.45, alpha: 0.65))
    ctx.addArc(center: loupeCenter, radius: loupeRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 0.95, blue: 0.92, alpha: 0.88))
    ctx.setLineWidth(12)
    ctx.strokePath()

    ctx.addArc(center: loupeCenter, radius: loupeRadius - 6, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.clip()
    let lensColors = [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.25),
        CGColor(red: 1.0, green: 0.85, blue: 0.85, alpha: 0.04)
    ] as CFArray
    if let lensGrad = CGGradient(colorsSpace: colorSpace, colors: lensColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            lensGrad,
            start: CGPoint(x: 360, y: 660),
            end: CGPoint(x: 660, y: 340),
            options: []
        )
    }
    ctx.restoreGState()

    // 5. Dynamic Origami Crimson Ribbon Bookmark
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 20 * scale, color: CGColor(red: 0.30, green: 0.0, blue: 0.06, alpha: 0.45))

    let upperRibbon = CGMutablePath()
    upperRibbon.move(to: CGPoint(x: 558, y: 782))
    upperRibbon.addLine(to: CGPoint(x: 652, y: 794))
    upperRibbon.addLine(to: CGPoint(x: 604, y: 536))
    upperRibbon.addLine(to: CGPoint(x: 504, y: 468))
    upperRibbon.closeSubpath()

    ctx.saveGState()
    ctx.addPath(upperRibbon)
    ctx.clip()
    let upperRibColors = [
        CGColor(red: 1.0, green: 0.48, blue: 0.38, alpha: 1.0),
        CGColor(red: 0.82, green: 0.10, blue: 0.24, alpha: 1.0)
    ] as CFArray
    if let g1 = CGGradient(colorsSpace: colorSpace, colors: upperRibColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(g1, start: CGPoint(x: 610, y: 790), end: CGPoint(x: 540, y: 470), options: [])
    }
    ctx.restoreGState()

    let midRibbon = CGMutablePath()
    midRibbon.move(to: CGPoint(x: 476, y: 562))
    midRibbon.addLine(to: CGPoint(x: 604, y: 536))
    midRibbon.addLine(to: CGPoint(x: 504, y: 468))
    midRibbon.addLine(to: CGPoint(x: 410, y: 492))
    midRibbon.closeSubpath()

    ctx.saveGState()
    ctx.addPath(midRibbon)
    ctx.clip()
    let midRibColors = [
        CGColor(red: 0.98, green: 0.36, blue: 0.30, alpha: 1.0),
        CGColor(red: 0.68, green: 0.05, blue: 0.16, alpha: 1.0)
    ] as CFArray
    if let g2 = CGGradient(colorsSpace: colorSpace, colors: midRibColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(g2, start: CGPoint(x: 420, y: 540), end: CGPoint(x: 590, y: 480), options: [])
    }
    ctx.restoreGState()

    let lowerRibbon = CGMutablePath()
    lowerRibbon.move(to: CGPoint(x: 410, y: 492))
    lowerRibbon.addLine(to: CGPoint(x: 504, y: 468))
    lowerRibbon.addLine(to: CGPoint(x: 518, y: 278))
    lowerRibbon.addLine(to: CGPoint(x: 444, y: 214))
    lowerRibbon.closeSubpath()

    ctx.saveGState()
    ctx.addPath(lowerRibbon)
    ctx.clip()
    let lowRibColors = [
        CGColor(red: 0.76, green: 0.06, blue: 0.18, alpha: 1.0),
        CGColor(red: 0.94, green: 0.28, blue: 0.22, alpha: 1.0)
    ] as CFArray
    if let g3 = CGGradient(colorsSpace: colorSpace, colors: lowRibColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(g3, start: CGPoint(x: 450, y: 490), end: CGPoint(x: 480, y: 214), options: [])
    }
    ctx.restoreGState()
    ctx.restoreGState()

    // 6. Outer Metallic Rim Highlight on Squircle
    addRoundedRect(ctx, rect: iconRect.insetBy(dx: 3, dy: 3), radius: cornerRadius - 3)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 0.82, blue: 0.80, alpha: 0.55))
    ctx.setLineWidth(6.0)
    ctx.strokePath()

    ctx.restoreGState()

    guard let cgImage = ctx.makeImage() else {
        fatalError("Failed to create CGImage")
    }
    let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG")
    }
    return pngData
}

func buildICNSData(chunks: [(type: String, pngData: Data)]) -> Data {
    var body = Data()
    for chunk in chunks {
        guard let typeBytes = chunk.type.data(using: .ascii), typeBytes.count == 4 else { continue }
        let chunkLen = UInt32(8 + chunk.pngData.count).bigEndian
        body.append(typeBytes)
        withUnsafeBytes(of: chunkLen) { body.append(contentsOf: $0) }
        body.append(chunk.pngData)
    }
    var icns = Data()
    icns.append("icns".data(using: .ascii)!)
    let totalLen = UInt32(8 + body.count).bigEndian
    withUnsafeBytes(of: totalLen) { icns.append(contentsOf: $0) }
    icns.append(body)
    return icns
}

let png1024 = renderIconImage(pixelSize: 1024)
let png512  = renderIconImage(pixelSize: 512)
let png256  = renderIconImage(pixelSize: 256)
let png128  = renderIconImage(pixelSize: 128)
let png64   = renderIconImage(pixelSize: 64)
let png32   = renderIconImage(pixelSize: 32)
let png16   = renderIconImage(pixelSize: 16)

let pngPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/Users/linqingyong/Documents/spark/SimplePDFReader/AppIcon.png"
let icnsPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "/Users/linqingyong/Documents/spark/SimplePDFReader/AppIcon.icns"

try png1024.write(to: URL(fileURLWithPath: pngPath))

let icnsData = buildICNSData(chunks: [
    ("icp4", png16),
    ("icp5", png32),
    ("icp6", png64),
    ("ic07", png128),
    ("ic08", png256),
    ("ic09", png512),
    ("ic10", png1024),
    ("ic11", png32),
    ("ic12", png64),
    ("ic13", png512),
    ("ic14", png1024)
])
try icnsData.write(to: URL(fileURLWithPath: icnsPath))
print("Generated AppIcon.png (\(png1024.count) bytes) and AppIcon.icns (\(icnsData.count) bytes)")
