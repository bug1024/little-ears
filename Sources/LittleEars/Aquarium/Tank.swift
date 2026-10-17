import AppKit
import MetalKit
import simd

struct TankPart: Decodable { let name: String; let texture: Int; let vertices: [[Float]]; let sway: Float; let pivot: [Float]; let motion: [Float] }
struct TankAsset: Decodable { let id: Int; let name: String; let parts: [TankPart]; let bounds: [[Float]]; let spawnScale: Float?; let collisionRadius: Float? }
struct TankTexture: Decodable { let name: String; let file: String; let width: Int; let height: Int; let transparent: Bool }
struct TankData: Decodable { let species: [TankAsset]; let scenery: [TankAsset]; let textures: [TankTexture]; let collisionTriangles: [[Float]]; let collisionMargins: [Float]; let lightplayTexture: Int; let bubbleTexture: Int? }
struct TankUniforms {
    var model: simd_float4x4
    var viewProjection: simd_float4x4
    var options: SIMD4<Float>
    var water: SIMD4<Float>
    var camera: SIMD4<Float>
    var detail: SIMD4<Float>
    var pivot: SIMD4<Float>
    var motion: SIMD4<Float>
    var lightProjection: simd_float4x4
}
struct TankBatch { let assetID: Int; let buffer: MTLBuffer; let count: Int; let texture: Int; let fin: Bool; let sway: Float; let pivot: SIMD4<Float>; let motion: SIMD4<Float> }

final class TankRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let data: TankData
    var simulation: TankSimulation
    let solidPipeline: MTLRenderPipelineState
    let alphaPipeline: MTLRenderPipelineState
    let backgroundPipeline: MTLRenderPipelineState
    let bubblePipeline: MTLRenderPipelineState
    let particlePipeline: MTLRenderPipelineState
    let jellyPipeline: MTLRenderPipelineState
    let shadowPipeline: MTLRenderPipelineState
    var shadowMap: MTLTexture
    let depthWrite: MTLDepthStencilState
    let depthRead: MTLDepthStencilState
    let noDepth: MTLDepthStencilState
    let textures: [MTLTexture]
    let reef: [TankBatch]
    let species: [[TankBatch]]
    var running = true
    var simulationRate: Float = 1
    var fishCounts: [Int: Int]? = nil
    var showMoray = true
    var showStarfish = true
    var moonJellyCount = 0
    var caustics = true
    var bubbles = true
    var backgroundMotion = true
    var blueBackdrop = false
    let cameraPosition = SIMD3<Float>(AquariumLayout.centerX, 1.0, 22)
    private var last = ProcessInfo.processInfo.systemUptime

    init(assets: URL, shader: URL, shadowResolution: Int = 2048, population: [Int: Int]? = nil) throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { throw AquariumError.unavailable("Metal unavailable") }
        device = d; queue = q
        data = try JSONDecoder().decode(TankData.self, from: Data(contentsOf: assets.appendingPathComponent("tank.json")))
        let profiles = try data.species.map { asset -> FishProfile in
            guard let scale = asset.spawnScale, let radius = asset.collisionRadius, scale > 0, radius > 0 else { throw AquariumError.unavailable("Missing fish size metadata: " + asset.name) }
            return FishProfile(spawnScale: scale, collisionRadius: radius)
        }
        let fishAssets = data.species
        let indices = fishAssets.indices.flatMap { index in Array(repeating: index, count: population.map { $0[fishAssets[index].id] ?? 0 } ?? 1) }
        simulation = try TankSimulation(collider: ReefCollider(points: data.collisionTriangles, margins: data.collisionMargins), profiles: indices.map { profiles[$0] }, speciesIndices: indices)
        fishCounts = population
        let library = try d.makeLibrary(source: String(contentsOf: shader, encoding: .utf8), options: nil)
        func pipeline(_ vertex: String, _ fragment: String, _ blend: Bool) throws -> MTLRenderPipelineState {
            let p = MTLRenderPipelineDescriptor(); p.vertexFunction = library.makeFunction(name: vertex); p.fragmentFunction = library.makeFunction(name: fragment)
            p.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb; p.depthAttachmentPixelFormat = .depth32Float
            if blend {
                let a = p.colorAttachments[0]!; a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .sourceAlpha; a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try d.makeRenderPipelineState(descriptor: p)
        }
        let shadowDescriptor = MTLRenderPipelineDescriptor()
        shadowDescriptor.vertexFunction = library.makeFunction(name: "tankVertex")
        shadowDescriptor.fragmentFunction = library.makeFunction(name: "tankShadow")
        shadowDescriptor.depthAttachmentPixelFormat = .depth32Float
        shadowPipeline = try d.makeRenderPipelineState(descriptor: shadowDescriptor)
        let shadowTexture = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: shadowResolution, height: shadowResolution, mipmapped: false)
        shadowTexture.storageMode = .private; shadowTexture.usage = [.renderTarget, .shaderRead]
        guard let map = d.makeTexture(descriptor: shadowTexture) else { throw AquariumError.unavailable("Shadow map allocation failed") }
        shadowMap = map
        solidPipeline = try pipeline("tankVertex", "tankFragment", false)
        alphaPipeline = try pipeline("tankVertex", "tankFragment", true)
        backgroundPipeline = try pipeline("backgroundVertex", "tankBackground", false)
        bubblePipeline = try pipeline("bubbleColumnVertex", "bubbleColumnFragment", true)
        particlePipeline = try pipeline("particleVertex", "particleFragment", true)
        jellyPipeline = try pipeline("moonJellyVertex", "moonJellyFragment", true)
        let depth = MTLDepthStencilDescriptor(); depth.depthCompareFunction = .less; depth.isDepthWriteEnabled = true
        depthWrite = d.makeDepthStencilState(descriptor: depth)!
        depth.isDepthWriteEnabled = false; depthRead = d.makeDepthStencilState(descriptor: depth)!
        depth.depthCompareFunction = .always; noDepth = d.makeDepthStencilState(descriptor: depth)!
        textures = try data.textures.map { t in
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: t.width, height: t.height, mipmapped: true)
            desc.storageMode = .shared; desc.usage = [.shaderRead]
            let texture = d.makeTexture(descriptor: desc)!
            let bytes = try Data(contentsOf: assets.appendingPathComponent(t.file))
            guard bytes.count == t.width * t.height * 4 else { throw AquariumError.unavailable("Invalid texture: \(t.name)") }
            bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: t.width * 4) }
            return texture
        }
        func batches(_ a: TankAsset, fish: Bool) -> [TankBatch] {
            a.parts.map { p in
                let vertices = p.vertices.flatMap { $0 }
                let buffer = vertices.withUnsafeBytes { d.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
                return TankBatch(assetID: a.id, buffer: buffer, count: p.vertices.count, texture: p.texture, fin: fish && p.name.contains("fin"), sway: p.sway, pivot: SIMD4(p.pivot[0], p.pivot[1], p.pivot[2], p.pivot[3]), motion: SIMD4(p.motion[0], p.motion[1], p.motion[2], p.motion[3]))
            }
        }
        reef = data.scenery.flatMap { batches($0, fish: false) }
        species = data.species.map { batches($0, fish: true) }
        super.init()
        let command = q.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
        for texture in textures { blit.generateMipmaps(for: texture) }
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
    }

    func resizeShadowMap(to resolution: Int) throws {
        guard shadowMap.width != resolution else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: resolution, height: resolution, mipmapped: false)
        desc.storageMode = .private; desc.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else { throw AquariumError.unavailable("Shadow map allocation failed") }
        shadowMap = texture
    }
    func resetFrameClock() { last = ProcessInfo.processInfo.systemUptime }

    func viewProjection(width: Int, height: Int) -> simd_float4x4 {
        let aspect = Float(max(1, width)) / Float(max(1, height))
        // Preserve the authored 16:9 horizontal view on taller windows/screens.
        // A fixed vertical FOV cropped the cave and the exposed moray head.
        let verticalScale = min(1, aspect / (16.0 / 9.0))
        let f: Float = verticalScale / tan(0.40 / 2)
        let near: Float = 0.1, far: Float = 80
        // Off-axis projection keeps the existing seabed bottom anchored.
        let p = simd_float4x4(columns: (SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0), SIMD4(0, 1 - verticalScale, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)))
        var v = matrix_identity_float4x4; v.columns.3 = SIMD4(-cameraPosition, 1)
        return p * v
    }

    var lightProjection: simd_float4x4 {
        let eye = SIMD3<Float>(AquariumLayout.centerX - 9, 16, 10), forward = simd_normalize(-SIMD3<Float>(-9, 16, 10))
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_cross(right, forward)
        let view = simd_float4x4(rows: [SIMD4(right, -simd_dot(right, eye)), SIMD4(up, -simd_dot(up, eye)), SIMD4(-forward, simd_dot(forward, eye)), SIMD4(0, 0, 0, 1)])
        let near: Float = 0.1, far: Float = 50
        let projection = simd_float4x4(columns: (SIMD4(1 / 17, 0, 0, 0), SIMD4(0, 1 / 12, 0, 0), SIMD4(0, 0, 1 / (near - far), 0), SIMD4(0, 0, near / (near - far), 1)))
        return projection * view
    }

    func encodeShadows(_ command: MTLCommandBuffer) {
        // Separate depth pass uses the same animated vertices and alpha cutouts.
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = shadowMap
        pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1
        if let e = command.makeRenderCommandEncoder(descriptor: pass) {
            encode(e, width: shadowMap.width, height: shadowMap.height, shadowPass: true)
            e.endEncoding()
        }
    }

    func encode(_ e: MTLRenderCommandEncoder, width: Int, height: Int, shadowPass: Bool = false) {
        let vp = shadowPass ? lightProjection : viewProjection(width: width, height: height)
        var u = TankUniforms(model: matrix_identity_float4x4, viewProjection: vp, options: SIMD4(simulation.time, 1, 1, caustics ? 1 : 0), water: SIMD4(0, 1, blueBackdrop ? 1 : 0, 0), camera: SIMD4(cameraPosition, 1), detail: SIMD4(0, 1, backgroundMotion ? 1 : 0, 2), pivot: .zero, motion: .zero, lightProjection: lightProjection)
        if !shadowPass {
            e.setDepthStencilState(noDepth); e.setRenderPipelineState(backgroundPipeline)
            e.setFragmentBytes(&u, length: MemoryLayout<TankUniforms>.stride, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.setFragmentTexture(shadowMap, index: 2)
        }
        e.setCullMode(.none); e.setTriangleFillMode(.fill)
        e.setFragmentTexture(textures[data.lightplayTexture], index: 1)
        func draw(_ batch: TankBatch, _ uniform: TankUniforms) {
            var uniform = uniform; uniform.detail.x = batch.assetID == 418 ? -1 : batch.sway
            uniform.pivot = batch.pivot; uniform.motion = batch.motion
            e.setRenderPipelineState(shadowPass ? shadowPipeline : batch.fin ? alphaPipeline : solidPipeline)
            e.setDepthStencilState(!shadowPass && batch.fin ? depthRead : depthWrite)
            e.setVertexBuffer(batch.buffer, offset: 0, index: 0)
            e.setVertexBytes(&uniform, length: MemoryLayout<TankUniforms>.stride, index: 1)
            e.setFragmentBytes(&uniform, length: MemoryLayout<TankUniforms>.stride, index: 1)
            e.setFragmentTexture(textures[batch.texture], index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: batch.count)
        }
        for b in reef where (b.assetID != 438 || showMoray) && (b.assetID != 299 || showStarfish) && (!shadowPass || data.textures[b.texture].name.lowercased() != "gravelfront.dds") { draw(b, u) }
        // Opaque fish write depth first; all transparent fins are a later pass.
        do {
            let ordered = simulation.swimmers.sorted { $0.position.z < $1.position.z }
            for transparent in [false, true] {
                for fish in ordered {
                    var model = rotation(yaw: fish.heading, pitch: 0)
                    // Source fish faces local -X. Pitch about local Z follows
                    // ascent/descent before yaw, rather than tilting the whole tank.
                    let pitch = min(0.22, max(-0.22, atan2(fish.velocity.y, max(0.1, simd_length(SIMD2(fish.velocity.x, fish.velocity.z))))))
                    let tilt = simd_float4x4(columns: (SIMD4(cos(pitch), -sin(pitch), 0, 0), SIMD4(sin(pitch), cos(pitch), 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
                    model = model * tilt
                    let bank = simd_float4x4(columns: (SIMD4(cos(fish.bank), sin(fish.bank), 0, 0), SIMD4(-sin(fish.bank), cos(fish.bank), 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
                    model = bank * model
                    for i in 0..<3 { model[i] *= fish.scale }
                    model.columns.3 = SIMD4(fish.position, 1)
                    u.model = model; u.options.z = 0; u.water.x = fish.phase
                    u.water.y = max(0.4, simd_length(fish.velocity) / fish.cruise)
                    for b in species[fish.species] where b.fin == transparent { draw(b, u) }
                }
            }
        }
        if moonJellyCount > 0 && !shadowPass {
            u.model = matrix_identity_float4x4
            e.setTriangleFillMode(.fill); e.setRenderPipelineState(jellyPipeline); e.setDepthStencilState(depthRead)
            e.setVertexBytes(&u, length: MemoryLayout<TankUniforms>.stride, index: 1)
            e.setFragmentBytes(&u, length: MemoryLayout<TankUniforms>.stride, index: 1)
            // Three parametric meshes per animal: bell, four oral arms, short marginal fringe.
            for index in [2, 4, 0, 3, 1] where index < min(5, moonJellyCount) {
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: (2 * 48 * 96 + 4 * 64 * 16 + 96 * 8) * 6, instanceCount: 1, baseInstance: index)
            }
        }
        if bubbles && !shadowPass {
            u.model = matrix_identity_float4x4
            e.setRenderPipelineState(bubblePipeline); e.setDepthStencilState(depthRead)
            e.setVertexBytes(&u, length: MemoryLayout<TankUniforms>.stride, index: 1)
            e.setFragmentBytes(&u, length: MemoryLayout<TankUniforms>.stride, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 160)
        }
        if !shadowPass {
            u.model = matrix_identity_float4x4
            e.setTriangleFillMode(.fill); e.setRenderPipelineState(particlePipeline); e.setDepthStencilState(depthRead)
            e.setVertexBytes(&u, length: MemoryLayout<TankUniforms>.stride, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 16)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        let now = ProcessInfo.processInfo.systemUptime, delta = now - last; last = now
        guard !NSApp.isHidden, let window = view.window, !window.isMiniaturized, window.occlusionState.contains(.visible) else { return }
        if running {
            let steps = min(4, max(1, Int(ceil(delta * 60))))
            for _ in 0..<steps { simulation.step(Float(min(delta, 1 / 15)) / Float(steps) * simulationRate) }
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else { return }
        encodeShadows(command)
        guard let e = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encode(e, width: Int(view.drawableSize.width), height: Int(view.drawableSize.height)); e.endEncoding()
        if PerformanceSession.enabled { PerformanceSession.track(command: command) }
        command.present(drawable); command.commit()
    }

}
