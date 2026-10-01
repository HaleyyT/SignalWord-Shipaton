// Packages the existing viewer/favicon.svg mark as an opaque iOS icon.
// No new visual design: geometry and colours match the existing brand mark.
import AppKit
import ImageIO
import UniformTypeIdentifiers
let output = CommandLine.arguments[1]
let space = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                        bytesPerRow: 4096, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.scaleBy(x: 16, y: 16)
context.translateBy(x: 0, y: 64)
context.scaleBy(x: 1, y: -1)
let dark = CGColor(red: 11/255, green: 13/255, blue: 16/255, alpha: 1)
context.setFillColor(dark)
context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
context.setFillColor(CGColor(red: 122/255, green: 111/255, blue: 240/255, alpha: 1))
let bubble = CGMutablePath()
bubble.move(to: CGPoint(x:14,y:17))
bubble.addQuadCurve(to: CGPoint(x:21,y:10), control: CGPoint(x:14,y:10))
bubble.addLine(to: CGPoint(x:43,y:10))
bubble.addQuadCurve(to: CGPoint(x:50,y:17), control: CGPoint(x:50,y:10))
bubble.addLine(to: CGPoint(x:50,y:36))
bubble.addQuadCurve(to: CGPoint(x:43,y:43), control: CGPoint(x:50,y:43))
bubble.addLine(to: CGPoint(x:31,y:43));bubble.addLine(to: CGPoint(x:21,y:52))
bubble.addLine(to: CGPoint(x:21,y:43))
bubble.addQuadCurve(to: CGPoint(x:14,y:36), control: CGPoint(x:14,y:43))
bubble.closeSubpath();context.addPath(bubble);context.fillPath()
context.setStrokeColor(dark);context.setLineWidth(4.5)
context.setLineCap(.round);context.setLineJoin(.round)
context.addLines(between: [(19,27),(23,27),(26,20),(32,37),(37,24),(41,32),(44,27),(46,27)].map{CGPoint(x:$0.0,y:$0.1)})
context.strokePath()
let destination=CGImageDestinationCreateWithURL(URL(fileURLWithPath:output) as CFURL, UTType.png.identifier as CFString, 1,nil)!
CGImageDestinationAddImage(destination,context.makeImage()!,nil)
precondition(CGImageDestinationFinalize(destination))
