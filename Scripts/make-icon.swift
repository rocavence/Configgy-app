#!/usr/bin/env swift
//
// Render Zennly's app icon at 1024×1024 → Resources/icon-1024.png
// Concept: an ensō (Zen brush circle), left open with a small arrowhead at the
// opening so it reads as "cycle / restore". Off-white ink on a calm gradient.
// Run from project root:  swift Scripts/make-icon.swift
//
import AppKit
import CoreGraphics
import ImageIO

let size: CGFloat = 1024
let inset: CGFloat = 96
let squircleCorner: CGFloat = 228   // macOS Tahoe app-squircle proportion

let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("ctx")
}
let bounds = CGRect(x: 0, y: 0, width: size, height: size)
ctx.clear(bounds)

let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = CGPath(roundedRect: rect, cornerWidth: squircleCorner, cornerHeight: squircleCorner, transform: nil)

// ---- background: calm indigo → night gradient ----
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [
    NSColor(red: 0.17, green: 0.17, blue: 0.19, alpha: 1).cgColor,   // charcoal
    NSColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1).cgColor    // near-black (Zen-like)
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
// top sheen
let sheen = CGGradient(colorsSpace: space, colors: [
    NSColor.white.withAlphaComponent(0.16).cgColor,
    NSColor.white.withAlphaComponent(0).cgColor
] as CFArray, locations: [0, 0.5])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: rect.midX, y: rect.maxY),
                       end: CGPoint(x: rect.midX, y: rect.midY), options: [])
ctx.restoreGState()

// ---- ensō (open brush circle) ----
let cx = rect.midX, cy = rect.midY
let r = rect.width * 0.305
let lw = rect.width * 0.092
let ink = NSColor(red: 0.95, green: 0.93, blue: 0.87, alpha: 1.0)   // sumi paper white

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

// gap centred near the top (~52° wide). Stroke the long way round (308°, CCW).
let gapStart: CGFloat = 52, gapEnd: CGFloat = 104
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 36,
              color: NSColor.black.withAlphaComponent(0.33).cgColor)
ctx.setLineWidth(lw)
ctx.setLineCap(.round)
ctx.setStrokeColor(ink.cgColor)
ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r,
           startAngle: deg(gapEnd), endAngle: deg(gapStart), clockwise: false)
ctx.strokePath()
ctx.restoreGState()

// subtle brush sheen along the stroke (thin lighter arc on the outer edge)
ctx.saveGState()
ctx.setLineWidth(lw * 0.26)
ctx.setLineCap(.round)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.20).cgColor)
ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r + lw * 0.26,
           startAngle: deg(gapEnd + 8), endAngle: deg(gapStart + 8), clockwise: false)
ctx.strokePath()
ctx.restoreGState()

// ---- arrowhead at the gapStart end (right of the opening), sweeping CCW up into the gap ----
let a = deg(gapStart)
let end = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
let tang = CGPoint(x: -sin(a), y: cos(a))     // CCW tangent (direction of travel)
let norm = CGPoint(x: cos(a), y: sin(a))      // radial (outward)
let ah = lw * 0.92                            // arrow size
let jade = NSColor(red: 0.40, green: 0.82, blue: 0.72, alpha: 1.0)
let tip = CGPoint(x: end.x + tang.x * ah, y: end.y + tang.y * ah)
let bL  = CGPoint(x: end.x + norm.x * ah * 0.52, y: end.y + norm.y * ah * 0.52)
let bR  = CGPoint(x: end.x - norm.x * ah * 0.52, y: end.y - norm.y * ah * 0.52)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18,
              color: NSColor.black.withAlphaComponent(0.30).cgColor)
ctx.setFillColor(jade.cgColor)
ctx.beginPath()
ctx.move(to: tip); ctx.addLine(to: bL); ctx.addLine(to: bR); ctx.closePath()
ctx.fillPath()
ctx.restoreGState()

// ---- write PNG ----
guard let img = ctx.makeImage() else { fatalError("img") }
let url = URL(fileURLWithPath: "Resources/icon-1024.png")
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { fatalError("dest") }
CGImageDestinationAddImage(dest, img, nil)
if !CGImageDestinationFinalize(dest) { fatalError("write") }
print("→ wrote Resources/icon-1024.png")
