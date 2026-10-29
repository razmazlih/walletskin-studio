import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

enum ArtworkError: LocalizedError {
    case invalid, tooLarge, exportFailed
    var errorDescription: String? {
        switch self { case .invalid: return "לא ניתן לקרוא את התמונה / Invalid image"
        case .tooLarge: return "התמונה גדולה מדי (עד 80MB ו־60 מיליון פיקסלים) / Image too large"
        case .exportFailed: return "לא ניתן לשמור PNG / PNG export failed" }
    }
}
@MainActor final class ArtworkEditor: ObservableObject {
    @Published var image: NSImage?
    @Published private(set) var loadedURL: URL?
    @Published var stretchToFill = true
    @Published var removeLightMargins = true { didSet { updateEffectiveImage() } }
    private(set) var originalImage: NSImage?
    private var trimmedImage: NSImage?
    @Published var fitWholeImage = true
    @Published var zoom: Double = 1
    @Published var pan: CGSize = .zero
    @Published var error: String?
    var dragStart: CGSize?
    let width = 1536
    let height = 969
    func load(_ url: URL) {
        loadedURL = nil
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 80 * 1024 * 1024 else { throw ArtworkError.tooLarge }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0 else { throw ArtworkError.invalid }
            guard Double(w) * Double(h) <= 60_000_000 else { throw ArtworkError.tooLarge }
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(w,h)] as CFDictionary) else { throw ArtworkError.invalid }
            loadedURL = url
            originalImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            trimmedImage = Self.trimLightMargins(cg)
            stretchToFill = true; removeLightMargins = true; updateEffectiveImage()
            fitWholeImage = true; zoom = 1; pan = .zero; dragStart = nil; error = nil
        } catch { originalImage = nil; trimmedImage = nil; image = nil; stretchToFill = true; removeLightMargins = true; zoom = 1; pan = .zero; self.error = error.localizedDescription }
    }
    func clear() { loadedURL = nil; originalImage = nil; trimmedImage = nil; image = nil; stretchToFill = true; removeLightMargins = true; fitWholeImage = true; zoom = 1; pan = .zero; dragStart = nil; error = nil }
    private func updateEffectiveImage() {
        image = removeLightMargins ? (trimmedImage ?? originalImage) : originalImage
    }
    // Conservative, reversible detection of light neutral borders around dark artwork.
    // White artwork is left alone; the original decoded pixels remain available.
    private static func trimLightMargins(_ source: CGImage) -> NSImage? {
        let scale = min(1.0, 1024.0 / Double(max(source.width, source.height)))
        let w = max(1, Int(Double(source.width) * scale)), h = max(1, Int(Double(source.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard drawn, w > 20, h > 20 else { return nil }
        func light(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            let values = [Double(pixels[i]), Double(pixels[i+1]), Double(pixels[i+2])]
            return values.min()! > 216 && values.max()! - values.min()! < 22
        }
        func dark(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            return max(pixels[i], pixels[i+1], pixels[i+2]) < 153
        }
        let perimeter = (0..<w).flatMap { [($0, 0), ($0, h-1)] } + (0..<h).flatMap { [(0, $0), (w-1, $0)] }
        guard Double(perimeter.filter { light($0.0, $0.1) }.count) / Double(perimeter.count) > 0.98 else { return nil }
        var left = w, right = -1, top = h, bottom = -1
        for y in 0..<h { for x in 0..<w where dark(x,y) {
            left = min(left,x); right = max(right,x); top = min(top,y); bottom = max(bottom,y)
        } }
        let bw = right-left+1, bh = bottom-top+1
        guard bw >= w/2, bh >= h/2, left > 1, top > 1, right < w-2, bottom < h-2 else { return nil }
        let insetX = max(1,bw/8), insetY = max(1,bh/8)
        let edges = ((left+insetX)...(right-insetX)).flatMap { [($0,top+1),($0,bottom-1)] }
            + ((top+insetY)...(bottom-insetY)).flatMap { [(left+1,$0),(right-1,$0)] }
        guard Double(edges.filter { dark($0.0,$0.1) }.count) / Double(edges.count) > 0.75 else { return nil }
        let rect = CGRect(x: Double(left)/Double(w)*Double(source.width), y: Double(top)/Double(h)*Double(source.height), width: Double(bw)/Double(w)*Double(source.width), height: Double(bh)/Double(h)*Double(source.height)).integral
        guard let cropped = source.cropping(to:rect) else { return nil }
        // Remove only light background connected to the detected dark card boundary.
        // Flood fill never crosses the dark perimeter into white lettering or chip details.
        let outputScale = min(1.0, 2048.0 / Double(max(cropped.width,cropped.height)))
        let cw = max(1,Int(Double(cropped.width)*outputScale)), ch = max(1,Int(Double(cropped.height)*outputScale))
        var output = [UInt8](repeating:0,count:cw*ch*4)
        return output.withUnsafeMutableBytes { bytes -> NSImage? in
            guard let context = CGContext(data:bytes.baseAddress,width:cw,height:ch,bitsPerComponent:8,bytesPerRow:cw*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:cw,height:ch))
            context.draw(cropped,in:CGRect(x:0,y:0,width:cw,height:ch))
            let buffer = bytes.bindMemory(to:UInt8.self)
            var seen = [UInt8](repeating:0,count:cw*ch), queue = [Int]()
            func enqueue(_ pixel:Int) {
                guard seen[pixel] == 0 else { return }; seen[pixel] = 1
                let i = pixel*4
                let low = min(buffer[i],buffer[i+1],buffer[i+2]), high = max(buffer[i],buffer[i+1],buffer[i+2])
                guard low > 216, Int(high)-Int(low) < 22 else { return }
                queue.append(pixel)
            }
            for x in 0..<cw { enqueue(x); enqueue((ch-1)*cw+x) }
            for y in 0..<ch { enqueue(y*cw); enqueue(y*cw+cw-1) }
            var head = 0
            while head < queue.count {
                let pixel = queue[head]; head += 1; let x = pixel%cw, y = pixel/cw, i = pixel*4
                buffer[i] = 0; buffer[i+1] = 0; buffer[i+2] = 0; buffer[i+3] = 255
                if x > 0 { enqueue(pixel-1) }; if x+1 < cw { enqueue(pixel+1) }
                if y > 0 { enqueue(pixel-cw) }; if y+1 < ch { enqueue(pixel+cw) }
            }
            guard let result = context.makeImage() else { return nil }
            return NSImage(cgImage:result,size:NSSize(width:cw,height:ch))
        }
    }
    func geometry(in size: CGSize) -> (CGSize, CGSize) {
        guard let image, !stretchToFill else { return (size,.zero) }
        let scale = fitWholeImage
            ? min(size.width / image.size.width, size.height / image.size.height)
            : max(size.width / image.size.width, size.height / image.size.height) * zoom
        let rendered = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let offset = fitWholeImage ? CGSize.zero : CGSize(width: pan.width * max(0,(rendered.width-size.width)/2), height: pan.height * max(0,(rendered.height-size.height)/2))
        return (rendered, offset)
    }
    func render() throws -> Data {
        guard let image else { throw ArtworkError.invalid }
        let size = CGSize(width: width, height: height)
        let (rendered,offset) = geometry(in:size)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil, pixelsWide:width, pixelsHigh:height, bitsPerSample:8, samplesPerPixel:4, hasAlpha:true, isPlanar:false, colorSpaceName:.deviceRGB, bytesPerRow:0,bitsPerPixel:0), let context = NSGraphicsContext(bitmapImageRep:bitmap) else { throw ArtworkError.exportFailed }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSColor.white.setFill(); NSRect(origin:.zero,size:size).fill()
        image.draw(in:NSRect(x:(size.width-rendered.width)/2+offset.width,y:(size.height-rendered.height)/2-offset.height,width:rendered.width,height:rendered.height),from:.zero,operation:.sourceOver,fraction:1)
        context.cgContext.flush()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using:.png,properties:[:]) else { throw ArtworkError.exportFailed }
        return data
    }
    func preparedURL() throws -> URL {
        let folder = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("WalletSkin Studio/Artwork",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:folder.path)
        let url = folder.appendingPathComponent(UUID().uuidString + ".png")
        try render().write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        return url
    }
    func choose() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png,.jpeg,.heic]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "WalletSkin.png"
        if panel.runModal() == .OK, let url = panel.url {
            do { try render().write(to:url,options:.atomic) } catch { self.error = error.localizedDescription }
        }
    }
}
struct ArtworkCanvas: View {
    @ObservedObject var editor: ArtworkEditor
    var body: some View {
        GeometryReader { geo in
            let (rendered,offset) = editor.geometry(in:geo.size)
            ZStack {
                if editor.image != nil { Color.white } else {
                    LinearGradient(colors:[.blue.opacity(0.12),.cyan.opacity(0.07)],startPoint:.topLeading,endPoint:.bottomTrailing)
                }
                if let image = editor.image {
                    Image(nsImage:image).resizable().frame(width:rendered.width,height:rendered.height).offset(offset)
                } else {
                    VStack(spacing:10) { Image(systemName:"photo.badge.plus").font(.system(size:38)); Text("PNG · JPEG · HEIC").font(.caption) }.foregroundStyle(.secondary)
                }
            }.frame(width:geo.size.width,height:geo.size.height).clipped()
                .gesture(DragGesture().onChanged { value in
                    guard !editor.stretchToFill && !editor.fitWholeImage else { return }
                    if editor.dragStart == nil { editor.dragStart = editor.pan }
                    let dx = max(1,(rendered.width-geo.size.width)/2), dy = max(1,(rendered.height-geo.size.height)/2)
                    editor.pan = CGSize(width:min(1,max(-1,(editor.dragStart?.width ?? 0)+value.translation.width/dx)),height:min(1,max(-1,(editor.dragStart?.height ?? 0)+value.translation.height/dy)))
                }.onEnded { _ in editor.dragStart = nil })
        }.aspectRatio(1536.0/969.0,contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:18))
    }
}

@MainActor final class ArtworkLibrary: ObservableObject {
    @Published var revision = 0
    private var activeKey: String?
    private let storageRoot: URL?
    init(storageRoot: URL? = nil) { self.storageRoot = storageRoot }
    private func key(device: String, card: String) -> String {
        let bytes = Data((device + "\u{0}" + card).utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private func folder() throws -> URL {
        let base = try storageRoot ?? FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("WalletSkin Studio/CardArtwork",isDirectory:true)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:base.path)
        return base
    }
    func savedImage(device: String, card: String) -> NSImage? {
        guard let base = try? folder() else { return nil }
        return NSImage(contentsOf:base.appendingPathComponent(key(device:device,card:card) + ".png"))
    }
    func save(_ editor: ArtworkEditor) {
        guard let activeKey, editor.image != nil else { return }
        do {
            let url = try folder().appendingPathComponent(activeKey + ".png")
            try editor.render().write(to:url,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            revision += 1
        } catch { editor.error = error.localizedDescription }
    }
    func switchCard(device: String?, card: String?, editor: ArtworkEditor) {
        let next = device.flatMap { device in card.map { key(device:device,card:$0) } }
        guard next != activeKey else { return }
        save(editor)
        activeKey = next
        editor.clear()
        if let next, let base = try? folder() {
            let url = base.appendingPathComponent(next + ".png")
            if FileManager.default.fileExists(atPath:url.path) { editor.load(url) }
        }
    }
}
