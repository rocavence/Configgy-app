#!/usr/bin/env swift
//
// Render Configgy's app icon at 1024×1024 → Resources/icon-1024.png
// Concept: a stack of off-white "config cards" (multiple settings sources —
// Zen, Claude, …) on a Zen-black squircle, with a jade circular-restore badge
// so it reads as "back up & restore my configs".
// Run from project root:  swift Scripts/make-icon.swift
//
import AppKit
import CoreGraphics
import ImageIO

let size: CGFloat = 1024
let inset: CGFloat = 96
let squircleCorner: CGFloat = 228

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
func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

// ---- background: charcoal → near-black (Zen-like) ----
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [
    NSColor(red: 0.17, green: 0.17, blue: 0.19, alpha: 1).cgColor,
    NSColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1).cgColor
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
let sheen = CGGradient(colorsSpace: space, colors: [
    NSColor.white.withAlphaComponent(0.16).cgColor,
    NSColor.white.withAlphaComponent(0).cgColor
] as CFArray, locations: [0, 0.5])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: rect.midX, y: rect.maxY),
                       end: CGPoint(x: rect.midX, y: rect.midY), options: [])
ctx.restoreGState()

// ---- stack of config cards ----
let cx = rect.midX, cy = rect.midY
let cardW = rect.width * 0.48
let cardH = rect.width * 0.33
let corner = cardH * 0.18
let off = rect.width * 0.052
let paper = NSColor(red: 0.95, green: 0.93, blue: 0.87, alpha: 1.0)
let ink = NSColor(red: 0.13, green: 0.13, blue: 0.16, alpha: 1.0)
let jade = NSColor(red: 0.40, green: 0.82, blue: 0.72, alpha: 1.0)

// i=0 front (lower-right), back cards shift up-left
func cardRect(_ i: CGFloat) -> CGRect {
    CGRect(x: cx - cardW / 2 - i * off, y: cy - cardH / 2 + i * off, width: cardW, height: cardH)
}
let alphas: [CGFloat] = [1.0, 0.60, 0.32]   // index 0 = front
for i in [2, 1, 0] {
    let rr = cardRect(CGFloat(i))
    ctx.saveGState()
    if i == 0 {
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36,
                      color: NSColor.black.withAlphaComponent(0.38).cgColor)
    }
    ctx.addPath(CGPath(roundedRect: rr, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.setFillColor(paper.withAlphaComponent(alphas[i]).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
}

// front-card "settings rows"
let front = cardRect(0)
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setLineWidth(rect.width * 0.018)
ctx.setStrokeColor(ink.withAlphaComponent(0.50).cgColor)
let padX = front.width * 0.13
for k in 0..<3 {
    let yy = front.maxY - front.height * (0.30 + 0.22 * CGFloat(k))
    let w = front.width * (k == 2 ? 0.34 : 0.74)
    ctx.move(to: CGPoint(x: front.minX + padX, y: yy))
    ctx.addLine(to: CGPoint(x: front.minX + padX + w, y: yy))
}
ctx.strokePath()
ctx.restoreGState()

// ---- jade circular-restore badge at front card's lower-right ----
let bc = CGPoint(x: front.maxX - cardW * 0.02, y: front.minY + cardH * 0.02)
let br = rect.width * 0.135
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22,
              color: NSColor.black.withAlphaComponent(0.34).cgColor)
ctx.setFillColor(jade.cgColor)
ctx.addEllipse(in: CGRect(x: bc.x - br, y: bc.y - br, width: 2 * br, height: 2 * br))
ctx.fillPath()
ctx.restoreGState()

// white circular arrow inside the badge (open near top, arrowhead sweeping CCW)
let ar = br * 0.50
let lwb = br * 0.20
let gA: CGFloat = 70, gB: CGFloat = 30   // gap between gA(end) and gB(start)
ctx.saveGState()
ctx.setLineCap(.round); ctx.setLineWidth(lwb)
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.addArc(center: bc, radius: ar, startAngle: deg(gA), endAngle: deg(gB), clockwise: false)
ctx.strokePath()
ctx.restoreGState()

// arrowhead at the gB end
let a = deg(gB)
let end = CGPoint(x: bc.x + ar * cos(a), y: bc.y + ar * sin(a))
let tang = CGPoint(x: -sin(a), y: cos(a))     // CCW tangent
let norm = CGPoint(x: cos(a), y: sin(a))       // outward radial
let ah = lwb * 1.5
let tip = CGPoint(x: end.x + tang.x * ah, y: end.y + tang.y * ah)
let bL = CGPoint(x: end.x + norm.x * ah * 0.6, y: end.y + norm.y * ah * 0.6)
let bR = CGPoint(x: end.x - norm.x * ah * 0.6, y: end.y - norm.y * ah * 0.6)
ctx.setFillColor(NSColor.white.cgColor)
ctx.beginPath()
ctx.move(to: tip); ctx.addLine(to: bL); ctx.addLine(to: bR); ctx.closePath()
ctx.fillPath()

// ---- write PNG ----
guard let img = ctx.makeImage() else { fatalError("img") }
let url = URL(fileURLWithPath: "Resources/icon-1024.png")
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { fatalError("dest") }
CGImageDestinationAddImage(dest, img, nil)
if !CGImageDestinationFinalize(dest) { fatalError("write") }
print("→ wrote Resources/icon-1024.png")
