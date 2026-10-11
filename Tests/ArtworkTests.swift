import AppKit
import ImageIO
import UniformTypeIdentifiers

@main struct ArtworkTests {
    @MainActor static func main() throws {
        let editor = ArtworkEditor()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let image = NSImage(size:NSSize(width:200,height:100))
        image.lockFocus(); NSColor(calibratedRed:1,green:0,blue:0,alpha:1).setFill(); NSRect(x:0,y:0,width:200,height:100).fill(); image.unlockFocus()
        let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
        let url = folder.appendingPathComponent("input.png")
        try bitmap.representation(using:.png,properties:[:])!.write(to:url)
        let original = try Data(contentsOf:url)
        editor.load(url)
        precondition(editor.image != nil && editor.fitWholeImage)
        editor.stretchToFill = false
        editor.fitWholeImage = false
        let (size,offset) = editor.geometry(in:CGSize(width:1536,height:969))
        precondition(size.width >= 1536 && size.height >= 969 && offset == .zero)
        editor.zoom = 2; editor.pan = CGSize(width:1,height:-1)
        let (zoomed,panned) = editor.geometry(in:CGSize(width:1536,height:969))
        precondition(zoomed.width == size.width*2 && panned.width > 0 && panned.height < 0)
        let data = try editor.render()
        let rendered = NSBitmapImageRep(data:data)!
        precondition(rendered.pixelsWide == 1536 && rendered.pixelsHigh == 969)
        let color = rendered.colorAt(x:0,y:0)!.usingColorSpace(.deviceRGB)!
        precondition(color.redComponent > 0.9 && color.greenComponent < 0.5)
        // Four distinct edge markers prove that fitting retains the complete final artwork.
        let finalImage = NSImage(size:NSSize(width:200,height:100))
        finalImage.lockFocus()
        NSColor.black.setFill(); NSRect(x:0,y:0,width:200,height:100).fill()
        NSColor.red.setFill(); NSRect(x:0,y:35,width:20,height:30).fill()
        NSColor.green.setFill(); NSRect(x:180,y:35,width:20,height:30).fill()
        NSColor.blue.setFill(); NSRect(x:85,y:0,width:30,height:20).fill()
        NSColor.yellow.setFill(); NSRect(x:85,y:80,width:30,height:20).fill()
        finalImage.unlockFocus()
        let finalURL = folder.appendingPathComponent("final.png")
        try NSBitmapImageRep(data:finalImage.tiffRepresentation!)!.representation(using:.png,properties:[:])!.write(to:finalURL)
        editor.load(finalURL)
        precondition(editor.fitWholeImage && editor.stretchToFill)
        let (stretched, stretchedOffset) = editor.geometry(in:CGSize(width:1536,height:969))
        precondition(stretched == CGSize(width:1536,height:969) && stretchedOffset == .zero)
        let stretchBitmap = NSBitmapImageRep(data:try editor.render())!
        for point in [(40,484),(1496,484),(768,20),(768,948)] {
            let c = stretchBitmap.colorAt(x:point.0,y:point.1)!.usingColorSpace(.deviceRGB)!
            precondition(min(c.redComponent,c.greenComponent,c.blueComponent) < 0.2, "Stretch must preserve edge markers without white padding")
        }
        editor.stretchToFill = false
        editor.zoom = 4; editor.pan = CGSize(width:1,height:-1)
        let (fitted,fitOffset) = editor.geometry(in:CGSize(width:1536,height:969))
        precondition(fitted.width == 1536 && fitted.height == 768 && fitOffset == .zero, "Whole-image fitting must ignore stale crop controls")
        let fitBitmap = NSBitmapImageRep(data:try editor.render())!
        func rgb(_ x:Int,_ y:Int) -> NSColor { fitBitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)! }
        let padding = rgb(768,20)
        precondition(padding.redComponent > 0.95 && padding.greenComponent > 0.95 && padding.blueComponent > 0.95, "Fit padding must be white")
        let left = rgb(40,484), right = rgb(1496,484)
        precondition(left.redComponent > 0.8 && left.greenComponent < 0.2)
        precondition(right.greenComponent > 0.8 && right.redComponent < 0.2)
        let top = rgb(768,145), bottom = rgb(768,824)
        precondition(top.redComponent > 0.8 && top.greenComponent > 0.8 && top.blueComponent < 0.2)
        precondition(bottom.blueComponent > 0.8 && bottom.redComponent < 0.2)
        editor.image = NSImage(size:NSSize(width:1536,height:969))
        editor.image!.lockFocus(); NSColor.red.setFill(); NSRect(x:0,y:0,width:1536,height:969).fill(); editor.image!.unlockFocus()
        let exact = NSBitmapImageRep(data:try editor.render())!
        for point in [(0,0),(1535,0),(0,968),(1535,968)] {
            let corner = exact.colorAt(x:point.0,y:point.1)!.usingColorSpace(.deviceRGB)!
            precondition(corner.redComponent > 0.9 && corner.greenComponent < 0.2, "Matching aspect ratio must have no padding")
        }
        let bordered = NSImage(size:NSSize(width:200,height:140))
        bordered.lockFocus(); NSColor.white.setFill(); NSRect(x:0,y:0,width:200,height:140).fill()
        NSColor.black.setFill(); NSRect(x:20,y:20,width:160,height:100).fill(); bordered.unlockFocus()
        let borderURL = folder.appendingPathComponent("border.png")
        try NSBitmapImageRep(data:bordered.tiffRepresentation!)!.representation(using:.png,properties:[:])!.write(to:borderURL)
        editor.load(borderURL)
        precondition(editor.image!.size.width < editor.originalImage!.size.width, "Confident light border should trim")
        editor.removeLightMargins = false
        precondition(editor.image!.size == editor.originalImage!.size, "Trim must reverse without changing original")
        editor.removeLightMargins = true
        let noBorder = NSBitmapImageRep(data:try editor.render())!
        precondition(noBorder.colorAt(x:768,y:0)!.usingColorSpace(.deviceRGB)!.redComponent < 0.2)
        let rounded = NSImage(size:NSSize(width:200,height:140))
        rounded.lockFocus(); NSColor.white.setFill(); NSRect(x:0,y:0,width:200,height:140).fill()
        NSColor.black.setFill(); NSBezierPath(roundedRect:NSRect(x:20,y:20,width:160,height:100),xRadius:15,yRadius:15).fill()
        NSColor.white.setFill(); NSRect(x:90,y:60,width:20,height:20).fill(); rounded.unlockFocus()
        let roundedURL = folder.appendingPathComponent("rounded.png")
        let roundedData = NSBitmapImageRep(data:rounded.tiffRepresentation!)!.representation(using:.png,properties:[:])!
        try roundedData.write(to:roundedURL); editor.load(roundedURL)
        let roundedResult = NSBitmapImageRep(data:try editor.render())!
        precondition(roundedResult.colorAt(x:0,y:0)!.usingColorSpace(.deviceRGB)!.redComponent < 0.2, "Connected white corner background must become dark")
        precondition(roundedResult.colorAt(x:768,y:484)!.usingColorSpace(.deviceRGB)!.redComponent > 0.9, "Interior light artwork must remain unchanged")
        editor.removeLightMargins = false
        precondition(editor.image!.size == editor.originalImage!.size)
        let roundedUnchanged = try Data(contentsOf:roundedURL)
        precondition(roundedUnchanged == roundedData, "Background cleanup must never alter source")
        let white = NSImage(size:NSSize(width:200,height:140))
        white.lockFocus(); NSColor.white.setFill(); NSRect(x:0,y:0,width:200,height:140).fill()
        NSColor.black.setFill(); NSRect(x:90,y:60,width:20,height:20).fill(); white.unlockFocus()
        let whiteURL = folder.appendingPathComponent("white-art.png")
        try NSBitmapImageRep(data:white.tiffRepresentation!)!.representation(using:.png,properties:[:])!.write(to:whiteURL)
        editor.load(whiteURL)
        precondition(editor.image!.size == editor.originalImage!.size, "White artwork must not be mistaken for margins")
        for type in [UTType.jpeg, UTType.heic] {
            let encoded = folder.appendingPathComponent("fixture." + type.preferredFilenameExtension!)
            guard let destination = CGImageDestinationCreateWithURL(encoded as CFURL,type.identifier as CFString,1,nil) else { fatalError("Image encoder missing") }
            CGImageDestinationAddImage(destination,bitmap.cgImage!,[kCGImagePropertyOrientation:6] as CFDictionary)
            if !CGImageDestinationFinalize(destination) {
                if type == .heic { print("SKIP HEIC encoder unavailable in execution environment"); continue }
                fatalError("JPEG encoding failed")
            }
            editor.load(encoded)
            precondition(editor.image != nil && editor.error == nil)
            precondition(editor.image!.size.height > editor.image!.size.width, "EXIF orientation must rotate portrait")
            let converted = try editor.render()
            precondition(NSBitmapImageRep(data:converted) != nil)
        }
        let library = ArtworkLibrary(storageRoot:folder.appendingPathComponent("mapped"))
        library.switchCard(device:"test-device-a",card:"test-card-1",editor:editor)
        editor.load(url)
        library.switchCard(device:"test-device-b",card:"test-card-1",editor:editor)
        precondition(editor.image == nil, "Same card identifier on another device must not share artwork")
        library.switchCard(device:"test-device-a",card:"test-card-1",editor:editor)
        precondition(editor.image != nil, "Exact device/card artwork should persist")
        let untouched = try Data(contentsOf:url)
        precondition(untouched == original)
        let corrupt = folder.appendingPathComponent("broken.png")
        try Data("invalid".utf8).write(to:corrupt)
        editor.load(corrupt)
        precondition(editor.error != nil && editor.image == nil)
        print("PASS artwork PNG/JPEG import, EXIF orientation, stretch without padding, reversible conservative border trim, whole-image fit edge preservation and white padding, exact aspect ratio, legacy crop pixels, zoom/pan, dimensions, original preservation, exact card-device mapping, stale-image removal")
    }
}
