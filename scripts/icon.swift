import AppKit
let dir = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width:1024,height:1024))
image.lockFocus()
let background = NSBezierPath(roundedRect:NSRect(x:20,y:20,width:984,height:984),xRadius:215,yRadius:215)
NSColor(calibratedRed:0.08,green:0.30,blue:0.88,alpha:1).setFill(); background.fill()
let wallet = NSBezierPath(roundedRect:NSRect(x:180,y:280,width:664,height:440),xRadius:80,yRadius:80)
NSColor.white.setFill(); wallet.fill()
let card = NSBezierPath(roundedRect:NSRect(x:245,y:560,width:530,height:165),xRadius:30,yRadius:30)
NSColor(calibratedRed:0.54,green:0.77,blue:1,alpha:1).setFill(); card.fill()
let flap = NSBezierPath(roundedRect:NSRect(x:620,y:380,width:225,height:165),xRadius:42,yRadius:42)
NSColor(calibratedRed:0.17,green:0.45,blue:0.96,alpha:1).setFill(); flap.fill()
NSColor.white.setFill(); NSBezierPath(ovalIn:NSRect(x:670,y:435,width:50,height:50)).fill()
image.unlockFocus()
let rep = NSBitmapImageRep(data:image.tiffRepresentation!)!
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:dir))
