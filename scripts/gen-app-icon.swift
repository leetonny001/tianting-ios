#!/usr/bin/env swift
// Draws the app icon (PRD-ui 1.4 B-1: own design): the character 听 on the brand fill color (design/tokens.json
// color.brand.fill). Usage: swift scripts/gen-app-icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit
import CoreText

let size = 1024
let path = CommandLine.arguments[1]
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(CGColor(srgbRed: 0x4C / 255, green: 0x5F / 255, blue: 0xD5 / 255, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 620, nil)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 1, alpha: 1)]
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "听", attributes: attrs))
let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
ctx.textPosition = CGPoint(
    x: (CGFloat(size) - bounds.width) / 2 - bounds.minX, y: (CGFloat(size) - bounds.height) / 2 - bounds.minY)
CTLineDraw(line, ctx)
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
