import AppKit
import Foundation

// 生成 LaunchGrid 应用图标 v3 —— 「Field Notes」
//
// 配色与形态对齐 CacinieP 个人主页（github.com/CacinieP）的编辑/手册风格：
//   深青蓝 #244c57（蓝）· 低饱和赭黄 #d9b97a（黄）· 米白 #fbf8f2 · 墨线 #14262b
// 特征：哑光低饱和、直角化多过圆角、细描边而非投影、极简配色
//
// 输出标准 .iconset 目录，随后用 iconutil 合成 .icns

func rgb(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// 调色板（与个人主页 hero 同一套）
let ink: UInt32 = 0x14262B        // 墨绿黑
let blue: UInt32 = 0x244C57      // 深青蓝
let blueLight: UInt32 = 0x2E5F6D
let blueDeep: UInt32 = 0x1B3A44
let ochre: UInt32 = 0xD9B97A     // 低饱和赭黄
let ochreDeep: UInt32 = 0xC9A45F
let cream: UInt32 = 0xFBF8F2     // 米白
let paper: UInt32 = 0xF4F0E8

func drawIcon(into ctx: CGContext, pixels: CGFloat) {
    let s = pixels
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // ── 主体：macOS squircle ────────────────────────────────────
    let inset = s * 0.0995
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.2237

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()

    // 哑光斜向渐变（接近平涂，只留一点层次）
    if let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [rgb(blueLight), rgb(blueDeep)] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: body.minX, y: body.maxY),
            end: CGPoint(x: body.maxX, y: body.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // ── 内框细描边（呼应主页的 rect stroke 母题）───────────────
    let frameInset = body.width * 0.048
    let frame = body.insetBy(dx: frameInset, dy: frameInset)
    ctx.saveGState()
    ctx.setStrokeColor(rgb(paper, 0.20))
    ctx.setLineWidth(s * 0.0055)
    ctx.addPath(CGPath(roundedRect: frame, cornerWidth: frame.width * 0.16, cornerHeight: frame.width * 0.16, transform: nil))
    ctx.strokePath()
    ctx.restoreGState()

    // ── 2×2 格子（圆角比 macOS 常规更方，贴合编辑风格）──────────
    let tile = body.width * 0.285
    let gap = body.width * 0.052
    let gridSide = tile * 2 + gap
    let tileRadius = tile * 0.17
    let gridX = body.midX - gridSide / 2
    let gridY = body.midY - gridSide / 2

    func tileRect(row: Int, col: Int) -> CGRect {
        CGRect(
            x: gridX + CGFloat(col) * (tile + gap),
            y: gridY + CGFloat(1 - row) * (tile + gap),
            width: tile,
            height: tile
        )
    }

    // 三个赭黄格子
    for (row, col) in [(0, 0), (0, 1), (1, 0)] {
        let rect = tileRect(row: row, col: col)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil))
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [rgb(ochre), rgb(ochreDeep)] as CFArray,
            locations: [0, 1]
        ) {
            ctx.clip()
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.minY),
                options: []
            )
        }
        ctx.restoreGState()
    }

    // ── 右下角「活跃」块：米白底 + 墨线描边 + 墨线波形 ──────────
    // 对应主页里 INTENT / TOOLS / EVAL 那种「米白填充 + 墨线」的节点
    let active = tileRect(row: 1, col: 1)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: active, cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil))
    ctx.setFillColor(rgb(cream))
    ctx.fillPath()
    ctx.setStrokeColor(rgb(ink))
    ctx.setLineWidth(tile * 0.052)
    ctx.addPath(CGPath(roundedRect: active, cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil))
    ctx.strokePath()
    ctx.restoreGState()

    // 块内：进程活动波形
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: active, cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil))
    ctx.clip()
    ctx.setStrokeColor(rgb(ink))
    ctx.setLineWidth(tile * 0.085)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let points: [(CGFloat, CGFloat)] = [
        (0.14, 0.62), (0.32, 0.32), (0.50, 0.72), (0.68, 0.28), (0.86, 0.50),
    ]
    ctx.beginPath()
    ctx.move(to: CGPoint(x: active.minX + active.width * points[0].0,
                          y: active.minY + active.height * points[0].1))
    for p in points.dropFirst() {
        ctx.addLine(to: CGPoint(x: active.minX + active.width * p.0,
                                y: active.minY + active.height * p.1))
    }
    ctx.strokePath()
    ctx.restoreGState()
}

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    drawIcon(into: ctx.cgContext, pixels: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in variants {
    guard let data = render(pixels: px) else {
        print("FAIL \(name)")
        exit(1)
    }
    let path = (outDir as NSString).appendingPathComponent(name)
    try data.write(to: URL(fileURLWithPath: path))
    print("wrote \(name) \(px)x\(px)")
}
print("iconset ready at \(outDir)")
