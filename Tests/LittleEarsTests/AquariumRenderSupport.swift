import MetalKit
@testable import LittleEars

// Real GPU readback for rendering regression tests only.
extension TankRenderer {
    func offscreen(width: Int, height: Int) throws -> CGImage? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        desc.storageMode = .shared; desc.usage = [.renderTarget, .shaderRead]
        let color = device.makeTexture(descriptor: desc)!
        desc.pixelFormat = .depth32Float; desc.storageMode = .private; desc.usage = .renderTarget
        let depth = device.makeTexture(descriptor: desc)!
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare; pass.depthAttachment.clearDepth = 1
        let command = queue.makeCommandBuffer()!
        encodeShadows(command)
        let e = command.makeRenderCommandEncoder(descriptor: pass)!
        encode(e, width: width, height: height); e.endEncoding()
        command.commit(); command.waitUntilCompleted(); if let error = command.error { throw error }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        color.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        for i in stride(from: 0, to: pixels.count, by: 4) { pixels.swapAt(i, i + 2) }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

}
