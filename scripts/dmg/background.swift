import AppKit

let args = CommandLine.arguments
let out = args[1]
let scale = CGFloat(Double(args[2]) ?? 1)
let W: CGFloat = 640, H: CGFloat = 420
let iconY: CGFloat = 200, leftX: CGFloat = 170, rightX: CGFloat = 470

let px = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8,
                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
px.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: px)
let cg = NSGraphicsContext.current!.cgContext
cg.translateBy(x: 0, y: H)
cg.scaleBy(x: 1, y: -1)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }
let space = CGColorSpace(name: CGColorSpace.sRGB)!

let bg = CGGradient(colorsSpace: space, colors: [rgb(54, 128, 255), rgb(26, 86, 214), rgb(14, 52, 160)] as CFArray, locations: [0, 0.55, 1])!
cg.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: W, y: H), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

func glow(_ c: CGPoint, _ r: CGFloat, _ color: CGColor) {
    let g = CGGradient(colorsSpace: space, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
}
glow(CGPoint(x: 90, y: -40), 340, rgb(140, 200, 255, 0.45))
glow(CGPoint(x: 600, y: 430), 300, rgb(80, 40, 200, 0.35))
glow(CGPoint(x: leftX, y: iconY), 120, rgb(255, 255, 255, 0.16))
glow(CGPoint(x: rightX, y: iconY), 120, rgb(255, 255, 255, 0.16))

let card = CGRect(x: 40, y: 92, width: W - 80, height: 214)
let cardPath = CGPath(roundedRect: card, cornerWidth: 34, cornerHeight: 34, transform: nil)
cg.saveGState()
cg.addPath(cardPath); cg.clip()
let sheen = CGGradient(colorsSpace: space, colors: [rgb(255, 255, 255, 0.20), rgb(255, 255, 255, 0.06)] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(sheen, start: CGPoint(x: 0, y: card.minY), end: CGPoint(x: 0, y: card.maxY), options: [])
cg.restoreGState()
cg.addPath(cardPath)
cg.setStrokeColor(rgb(255, 255, 255, 0.35)); cg.setLineWidth(1); cg.strokePath()
let rim = CGPath(roundedRect: card.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 32.5, cornerHeight: 32.5, transform: nil)
cg.saveGState()
cg.addPath(rim); cg.clip()
let top = CGGradient(colorsSpace: space, colors: [rgb(255, 255, 255, 0.35), rgb(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(top, start: CGPoint(x: 0, y: card.minY), end: CGPoint(x: 0, y: card.minY + 26), options: [])
cg.restoreGState()

let ax0 = leftX + 92, ax1 = rightX - 92
for (i, x) in stride(from: ax0, through: ax1 - 36, by: 15).enumerated() {
    cg.setFillColor(rgb(255, 255, 255, 0.35 + 0.08 * CGFloat(i)))
    cg.fillEllipse(in: CGRect(x: x - 3, y: iconY - 3, width: 6, height: 6))
}
let head = CGMutablePath()
head.move(to: CGPoint(x: ax1 - 22, y: iconY - 16))
head.addLine(to: CGPoint(x: ax1, y: iconY))
head.addLine(to: CGPoint(x: ax1 - 22, y: iconY + 16))
cg.addPath(head)
cg.setStrokeColor(rgb(255, 255, 255, 0.95)); cg.setLineWidth(6); cg.setLineCap(.round); cg.setLineJoin(.round); cg.strokePath()

func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ alpha: CGFloat, y: CGFloat, tracking: CGFloat = 0) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let shadow = NSShadow(); shadow.shadowColor = NSColor(white: 0, alpha: 0.25); shadow.shadowBlurRadius = 6; shadow.shadowOffset = NSSize(width: 0, height: -1)
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(white: 1, alpha: alpha),
                                            .paragraphStyle: p, .kern: tracking, .shadow: shadow]
    NSGraphicsContext.saveGraphicsState()
    let flip = NSAffineTransform(); flip.translateX(by: 0, yBy: H); flip.scaleX(by: 1, yBy: -1); flip.concat()
    NSAttributedString(string: s, attributes: a).draw(in: NSRect(x: 0, y: H - y - size * 1.3, width: W, height: size * 1.4))
    NSGraphicsContext.restoreGraphicsState()
}
text("Install Swiftwarden", 26, .bold, 1, y: 30)
text("Drag the app onto the Applications folder", 14, .medium, 0.82, y: 64)
text("Unofficial Bitwarden client  ·  github.com/list-jonas/Swiftwarden", 11, .regular, 0.7, y: 356)

NSGraphicsContext.restoreGraphicsState()
try! px.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
