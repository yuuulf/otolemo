// 正方形のロゴ画像から、macOS のアイコン形状（1024 中 824 の角丸四角形と余白）に整えた
// 1024×1024 の PNG を作る。scripts/make-icon.sh から呼ぶ。
//
// 使い方: swift scripts/make-icon.swift <入力PNG> <出力PNG>
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <input.png> <output.png>\n".utf8))
    exit(64)
}

let inputURL = URL(filePath: arguments[1])
let outputURL = URL(filePath: arguments[2])

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let logo = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read \(inputURL.path)\n".utf8))
    exit(1)
}

// Apple のアイコンテンプレート（1024pt）に合わせた寸法。
let canvas: CGFloat = 1024
let body: CGFloat = 824
let cornerRadius: CGFloat = 185.4
let bodyRect = CGRect(x: (canvas - body) / 2, y: (canvas - body) / 2, width: body, height: body)

guard let context = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    exit(1)
}
context.interpolationQuality = .high

// テンプレートと同じく、角丸四角形の下に薄い影を落とす。
let shape = CGPath(roundedRect: bodyRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.3))
context.addPath(shape)
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fillPath()
context.restoreGState()

// ロゴを角丸四角形で切り抜いて描く。
context.addPath(shape)
context.clip()
context.draw(logo, in: bodyRect)

guard let icon = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(destination, icon, nil)
guard CGImageDestinationFinalize(destination) else {
    exit(1)
}
