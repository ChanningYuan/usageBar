// 生成 DMG 拖拽安装窗口的背景图（虚线弧形箭头 + 底部双语提示）。
// 只画"背景层"：箭头 + 提示文字；App 图标 / Applications 图标 / 它们的文字标签
// 都由 Finder 实时摆放，本图里绝不画，避免重叠。
//
// 用法： swift make-dmg-background.swift <输出目录>
// 产出： <输出目录>/background.png (600x420) + background@2x.png (1200x840)
//        外层 build-app.sh 再用 `tiffutil -cathidpicheck` 合成多分辨率 TIFF（Retina 清晰）。
//
// 坐标系：本文件按"左上原点、y 向下"思考（和 AppleScript / 文档版面一致），
// 画进 CoreGraphics（左下原点）时用 ty() 翻一下。

import AppKit
import ImageIO
import UniformTypeIdentifiers

let W: CGFloat = 600   // 内容区宽（点）
let H: CGFloat = 420   // 内容区高（点）

// 左上 y → 左下 y
func ty(_ y: CGFloat) -> CGFloat { H - y }

func makeImage(scale: CGFloat) -> CGImage {
    let pxW = Int(W * scale), pxH = Int(H * scale)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)            // 之后都按"点"绘制
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // 干净白底（usageBar 黑白极简，不要光晕/渐变）
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    // ── 左侧 App 图标投影 ──
    // usageBar.app 是"白圆角方块 + 黑 U"，白底上整张卡片几乎隐形。
    // Finder 把它摆在 (150,190)、可见方块 ~86pt；这里在同位置垫一个带柔和投影的白方块：
    // 方块本身白底上隐形，只透出四周阴影，真图标盖上去后看着像一张悬浮卡片。
    do {
        let side: CGFloat = 86, radius: CGFloat = 20
        let cx: CGFloat = 150, cyTop: CGFloat = 190
        let rect = CGRect(x: cx - side / 2, y: ty(cyTop) - side / 2, width: side, height: side)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14,
                      color: NSColor(white: 0, alpha: 0.30).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // ── 虚线弧形箭头：左图标(x150) → 右图标(x450)，对称浅下凹弧、末端实心箭头 ──
    let arrowColor = NSColor(white: 0.62, alpha: 1).cgColor
    ctx.setStrokeColor(arrowColor)
    ctx.setLineWidth(2.4)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let p0 = CGPoint(x: 206, y: ty(186))       // 起点（左图标右缘外，与图标中心齐高）
    let c1 = CGPoint(x: 272, y: ty(206))       // 对称浅下凹（belly ≈ 中心下 18pt）
    let c2 = CGPoint(x: 334, y: ty(206))
    let p1 = CGPoint(x: 392, y: ty(184))       // 终点 = 箭头尖（指向右图标，与中心齐高）

    ctx.saveGState()
    ctx.setLineDash(phase: 0, lengths: [7, 6])
    ctx.beginPath()
    ctx.move(to: p0)
    ctx.addCurve(to: p1, control1: c1, control2: c2)
    ctx.strokePath()
    ctx.restoreGState()

    // 箭头头（实线，沿终点切线方向开口）
    let ang = atan2(p1.y - c2.y, p1.x - c2.x)
    let headLen: CGFloat = 13
    let spread: CGFloat = 0.42                  // ~24°
    let h1 = CGPoint(x: p1.x - headLen * cos(ang - spread), y: p1.y - headLen * sin(ang - spread))
    let h2 = CGPoint(x: p1.x - headLen * cos(ang + spread), y: p1.y - headLen * sin(ang + spread))
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.beginPath()
    ctx.move(to: h1); ctx.addLine(to: p1); ctx.addLine(to: h2)
    ctx.strokePath()

    // ── 底部双语提示（居中）──
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns

    func drawCentered(_ s: String, topY: CGFloat, size: CGFloat, weight: NSFont.Weight, white: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(white: white, alpha: 1),
        ]
        let astr = NSAttributedString(string: s, attributes: attrs)
        let sz = astr.size()
        astr.draw(at: CGPoint(x: (W - sz.width) / 2, y: H - topY - sz.height))
    }

    drawCentered("请将图标拖拽到右侧以安装 usageBar", topY: 338, size: 13.5, weight: .regular, white: 0.40)
    drawCentered("Drag the icon to the right to install usageBar", topY: 364, size: 11, weight: .regular, white: 0.55)

    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("无法创建 PNG: \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, img, nil)
    if !CGImageDestinationFinalize(dest) {
        FileHandle.standardError.write("写 PNG 失败: \(path)\n".data(using: .utf8)!)
        exit(1)
    }
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
writePNG(makeImage(scale: 1), to: "\(outDir)/background.png")
writePNG(makeImage(scale: 2), to: "\(outDir)/background@2x.png")
print("✓ background.png + background@2x.png → \(outDir)")
