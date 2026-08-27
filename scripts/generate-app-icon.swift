#!/usr/bin/env swift

import AppKit
import Foundation

enum IconGenerationError: LocalizedError {
    case invalidArguments
    case cannotReadSource
    case cannotCreateBitmap(Int)
    case cannotEncodePNG(Int)
    case iconutilFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "用法：generate-app-icon.swift <1024px-source.png> <output.icns>"
        case .cannotReadSource:
            "无法读取图标源文件。"
        case let .cannotCreateBitmap(size):
            "无法创建 \(size)px 图标画布。"
        case let .cannotEncodePNG(size):
            "无法编码 \(size)px PNG。"
        case let .iconutilFailed(status):
            "iconutil 执行失败，状态码 \(status)。"
        }
    }
}

guard CommandLine.arguments.count == 3 else { throw IconGenerationError.invalidArguments }

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSImage(contentsOf: sourceURL) else { throw IconGenerationError.cannotReadSource }

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

let fileManager = FileManager.default
let iconsetURL = fileManager.temporaryDirectory
    .appendingPathComponent("SnapWeave-AppIcon-\(UUID().uuidString).iconset", isDirectory: true)
defer { try? fileManager.removeItem(at: iconsetURL) }
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func superellipsePath(in rect: CGRect, exponent: CGFloat = 4.6) -> CGPath {
    let path = CGMutablePath()
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let a = rect.width / 2
    let b = rect.height / 2
    let steps = 720

    for step in 0...steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosine = cos(angle)
        let sine = sin(angle)
        let x = center.x + a * (cosine < 0 ? -1 : 1) * pow(abs(cosine), 2 / exponent)
        let y = center.y + b * (sine < 0 ? -1 : 1) * pow(abs(sine), 2 / exponent)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

for variant in variants {
    let pixels = variant.pixels
    guard let bitmap = NSBitmapImageRep(
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
    ) else { throw IconGenerationError.cannotCreateBitmap(pixels) }

    bitmap.size = NSSize(width: pixels, height: pixels)
    guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconGenerationError.cannotCreateBitmap(pixels)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let bounds = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    graphics.cgContext.clear(bounds)
    graphics.cgContext.addPath(superellipsePath(in: bounds.insetBy(dx: 0.5, dy: 0.5)))
    graphics.cgContext.clip()
    graphics.imageInterpolation = .high
    source.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw IconGenerationError.cannotEncodePNG(pixels)
    }
    try png.write(to: iconsetURL.appendingPathComponent(variant.name), options: .atomic)
}

try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    throw IconGenerationError.iconutilFailed(process.terminationStatus)
}

print("已生成：\(outputURL.path)")
