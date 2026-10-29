// Original abstract artwork. No external assets, brands or payment details.
import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/StarterDesigns", isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let palettes: [(String, [NSColor])] = [
    ("midnight", [NSColor(srgbRed:0.06,green:0.10,blue:0.23,alpha:1), NSColor(srgbRed:0.21,green:0.31,blue:0.57,alpha:1)]),
    ("sage", [NSColor(srgbRed:0.13,green:0.29,blue:0.27,alpha:1), NSColor(srgbRed:0.51,green:0.65,blue:0.48,alpha:1)]),
    ("sunset", [NSColor(srgbRed:0.36,green:0.14,blue:0.25,alpha:1), NSColor(srgbRed:0.91,green:0.56,blue:0.34,alpha:1)])
]
for (name, colors) in palettes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1536,pixelsHigh:969,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    NSGradient(colors:colors)!.draw(in:NSRect(x:0,y:0,width:1536,height:969),angle:30)
    for i in 0..<7 {
        NSColor.white.withAlphaComponent(0.035 + Double(i)*0.012).setFill()
        NSBezierPath(ovalIn:NSRect(x:Double(600+i*90),y:Double(-520+i*40),width:1100,height:1100)).fill()
    }
    NSColor.white.withAlphaComponent(0.18).setStroke()
    for i in 0..<4 {
        let path=NSBezierPath(ovalIn:NSRect(x:Double(-630+i*85),y:Double(210+i*40),width:1150,height:1150))
        path.lineWidth=2; path.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using:.png,properties:[:])!.write(to:destination.appendingPathComponent(name+".png"))
}
