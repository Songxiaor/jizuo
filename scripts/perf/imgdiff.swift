import AppKit
import CoreGraphics
func load(_ p: String) -> (CGImage, [UInt8], Int, Int)? {
  guard let img = NSImage(contentsOfFile: p), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
  let w = cg.width, h = cg.height
  var buf = [UInt8](repeating: 0, count: w * h * 4)
  let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
  return (cg, buf, w, h)
}
let a = CommandLine.arguments[1], b = CommandLine.arguments[2], out = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil
guard let (_, pa, wa, ha) = load(a), let (_, pb, wb, hb) = load(b) else { print("load fail"); exit(2) }
if wa != wb || ha != hb { print("SIZE \(wa)x\(ha) vs \(wb)x\(hb)"); exit(1) }
var diff = 0; var maxd = 0
var minX = wa, minY = ha, maxX = 0, maxY = 0
var heat = [UInt8](repeating: 0, count: wa * ha * 4)
for y in 0..<ha { for x in 0..<wa {
  let i = (y * wa + x) * 4
  let d = max(abs(Int(pa[i]) - Int(pb[i])), abs(Int(pa[i+1]) - Int(pb[i+1])), abs(Int(pa[i+2]) - Int(pb[i+2])))
  if d > 24 { diff += 1; minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
    heat[i] = 255; heat[i+3] = 255 } else { heat[i] = pa[i] / 3; heat[i+1] = pa[i+1] / 3; heat[i+2] = pa[i+2] / 3; heat[i+3] = 255 }
  maxd = max(maxd, d)
} }
let pct = Double(diff) / Double(wa * ha) * 100
print(String(format: "%.3f%% pixels differ (%d), box=(%d,%d)-(%d,%d)", pct, diff, minX, minY, maxX, maxY))
if let out, diff > 0 {
  let ctx = CGContext(data: &heat, width: wa, height: ha, bitsPerComponent: 8, bytesPerRow: wa * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
  try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
}
