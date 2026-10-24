import AppKit
import Foundation

// 生成 LaunchGrid 应用图标 v4 —— 「Field Notes / 四格」
//
// 配色与形态对齐 CacinieP 个人主页（github.com/CacinieP）的编辑/手册风格：
//   深青蓝 #244c57（蓝）· 低饱和赭黄 #d9b97a（黄）· 米白 #fbf8f2 · 墨线 #14262b
// 特征：哑光低饱和、直角化多过圆角、细描边而非投影、极简配色
//
// v4 的变化：2×2 四格各自带上功能微符号，对应四个面板
//   左上 应用 = 迷你网格   右上 进程 = 活动波形
//   左下 剪贴板 = 剪贴板轮廓   右下 网络 = 节点连线（米白底，延续 v3 的「活跃」块）
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

    func roundRectPath(_ rect: CGRect, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// 格子局部坐标（0...1，y 轴向上）→ 实际点
    func pt(_ rect: CGRect, _ u: CGFloat, _ v: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * u, y: rect.minY + rect.height * v)
    }

    // MARK: 四个功能符号

    /// 应用：迷你网格
    func glyphApps(_ rect: CGRect) {
        let side = rect.width * 0.22
        let gap = rect.width * 0.10
        let total = side * 2 + gap
        let x0 = rect.midX - total / 2
        let y0 = rect.midY - total / 2
        ctx.setFillColor(rgb(ink))
        for row in 0..<2 {
            for col in 0..<2 {
                let sq = CGRect(
                    x: x0 + CGFloat(col) * (side + gap),
                    y: y0 + CGFloat(row) * (side + gap),
                    width: side,
                    height: side
                )
                ctx.addPath(roundRectPath(sq, side * 0.22))
                ctx.fillPath()
            }
        }
    }

    /// 进程：活动波形（沿用 v3 的母题）
    func glyphProcess(_ rect: CGRect) {
        let points: [(CGFloat, CGFloat)] = [
            (0.14, 0.62), (0.32, 0.32), (0.50, 0.72), (0.68, 0.28), (0.86, 0.50),
        ]
        ctx.setStrokeColor(rgb(ink))
        ctx.setLineWidth(rect.width * 0.085)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.move(to: pt(rect, points[0].0, points[0].1))
        for p in points.dropFirst() {
            ctx.addLine(to: pt(rect, p.0, p.1))
        }
        ctx.strokePath()
    }

    /// 剪贴板：板身 + 顶部夹子
    func glyphClipboard(_ rect: CGRect) {
        let board = CGRect(
            x: rect.minX + rect.width * 0.24,
            y: rect.minY + rect.height * 0.12,
            width: rect.width * 0.52,
            height: rect.height * 0.64
        )
        ctx.setStrokeColor(rgb(ink))
        ctx.setLineWidth(rect.width * 0.062)
        ctx.addPath(roundRectPath(board, rect.width * 0.07))
        ctx.strokePath()

        let clip = CGRect(
            x: rect.minX + rect.width * 0.39,
            y: rect.minY + rect.height * 0.68,
            width: rect.width * 0.22,
            height: rect.height * 0.20
        )
        ctx.setFillColor(rgb(ink))
        ctx.addPath(roundRectPath(clip, rect.width * 0.05))
        ctx.fillPath()
    }

    /// 网络：中心节点 + 三条连线（对应「连接」明细）
    func glyphNetwork(_ rect: CGRect) {
        let center = pt(rect, 0.5, 0.44)
        let satellites = [pt(rect, 0.17, 0.80), pt(rect, 0.83, 0.80), pt(rect, 0.5, 0.12)]

        ctx.setStrokeColor(rgb(ink))
        ctx.setLineWidth(rect.width * 0.055)
        ctx.setLineCap(.round)
        for node in satellites {
            ctx.beginPath()
            ctx.move(to: center)
            ctx.addLine(to: node)
            ctx.strokePath()
        }

        ctx.setFillColor(rgb(ink))
        for node in satellites {
            let r = rect.width * 0.085
            ctx.addEllipse(in: CGRect(x: node.x - r, y: node.y - r, width: r * 2, height: r * 2))
            ctx.fillPath()
        }
        let cr = rect.width * 0.105
        ctx.addEllipse(in: CGRect(x: center.x - cr, y: center.y - cr, width: cr * 2, height: cr * 2))
        ctx.fillPath()
    }

    // MARK: 四格：左上 应用 / 右上 进程 / 左下 剪贴板 / 右下 网络

    let cells: [(row: Int, col: Int, cream: Bool, glyph: (CGRect) -> Void)] = [
        (0, 0, false, glyphApps),
        (0, 1, false, glyphProcess),
        (1, 0, false, glyphClipboard),
        (1, 1, true, glyphNetwork),
    ]

    for cell in cells {
        let rect = tileRect(row: cell.row, col: cell.col)

        // 底色：赭黄渐变 / 米白平涂
        ctx.saveGState()
        ctx.addPath(roundRectPath(rect, tileRadius))
        ctx.clip()
        if cell.cream {
            ctx.setFillColor(rgb(cream))
            ctx.fill(rect)
        } else if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [rgb(ochre), rgb(ochreDeep)] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.minY),
                options: []
            )
        }
        ctx.restoreGState()

        // 墨线描边
        ctx.saveGState()
        ctx.setStrokeColor(rgb(ink))
        ctx.setLineWidth(tile * 0.042)
        ctx.addPath(roundRectPath(rect, tileRadius))
        ctx.strokePath()
        ctx.restoreGState()

        // 功能符号
        ctx.saveGState()
        ctx.addPath(roundRectPath(rect, tileRadius))
        ctx.clip()
        cell.glyph(rect)
        ctx.restoreGState()
    }
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
