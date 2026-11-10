import Foundation
import Metal
import MetalKit
import simd

final class MetalShared {
    static let shared = MetalShared()

    struct PipelineSet {
        let background: MTLRenderPipelineState
        let wave: MTLRenderPipelineState
        let particle: MTLRenderPipelineState
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private var pipelineSets: [Int: PipelineSet] = [:]

    func pipelines(for sampleCount: Int) -> PipelineSet {
        pipelineSets[sampleCount] ?? pipelineSets[1]!
    }

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this Mac")
        }
        guard let queue = device.makeCommandQueue() else {
            fatalError("Could not create a Metal command queue")
        }
        self.device = device
        self.commandQueue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: MetalShaders.source, options: nil)
        } catch {
            fatalError("Metal shader compilation failed: \(error)")
        }

        func pipeline(vertex: String, fragment: String,
                      blending: Bool, sampleCount: Int) -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.rasterSampleCount = sampleCount
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            if blending {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                if vertex == "particleVertex" {
                    attachment.rgbBlendOperation = .add
                    attachment.alphaBlendOperation = .add
                    attachment.sourceRGBBlendFactor = .one
                    attachment.sourceAlphaBlendFactor = .one
                    attachment.destinationRGBBlendFactor = .one
                    attachment.destinationAlphaBlendFactor = .one
                } else {
                    attachment.rgbBlendOperation = .add
                    attachment.alphaBlendOperation = .add
                    attachment.sourceRGBBlendFactor = .sourceAlpha
                    attachment.sourceAlphaBlendFactor = .one
                    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
            }
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                fatalError("Could not create Metal pipeline \(vertex)/\(fragment): \(error)")
            }
        }

        for sampleCount in [1, 2, 4] where sampleCount == 1 || device.supportsTextureSampleCount(sampleCount) {
            pipelineSets[sampleCount] = PipelineSet(
                background: pipeline(vertex: "bgVertex", fragment: "bgFragment",
                                     blending: false, sampleCount: sampleCount),
                wave: pipeline(vertex: "waveVertex", fragment: "waveFragment",
                               blending: true, sampleCount: sampleCount),
                particle: pipeline(vertex: "particleVertex", fragment: "particleFragment",
                                   blending: true, sampleCount: sampleCount)
            )
        }
    }
}

final class XMBCoreRenderer {
    private let shared = MetalShared.shared
    private let splinePipeline = SplinePipeline()
    private let splineTexture: MTLTexture
    private let backgroundBuffer: MTLBuffer
    private let gridVertexBuffer: MTLBuffer
    private let gridIndexBuffer: MTLBuffer
    private let gridIndexCount: Int
    private var seedBuffer: MTLBuffer?
    private var seedCount = 0
    private var seedVariantID = ""
    private var pipelines: MetalShared.PipelineSet
    private(set) var antiAliasing: AntiAliasingMode

    private(set) var variant: XMBVariant

    init(variant: XMBVariant, antiAliasing: AntiAliasingMode = .current) {
        self.variant = variant
        let effectiveAA = AntiAliasingMode.supported(antiAliasing)
        self.antiAliasing = effectiveAA
        self.pipelines = MetalShared.shared.pipelines(for: effectiveAA.sampleCount)
        let device = shared.device

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: SplinePipeline.splineWidth,
            height: SplinePipeline.splineHeight,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead]
        textureDescriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            fatalError("Could not create spline texture")
        }
        splineTexture = texture

        let bgVerts: [SIMD2<Float>] = [
            SIMD2<Float>(-1, -1), SIMD2<Float>(1, -1),
            SIMD2<Float>(-1, 1), SIMD2<Float>(1, 1),
        ]
        guard let bgBuffer = device.makeBuffer(bytes: bgVerts,
                                               length: MemoryLayout<SIMD2<Float>>.stride * bgVerts.count,
                                               options: .storageModeShared) else {
            fatalError("Could not create background buffer")
        }
        backgroundBuffer = bgBuffer

        let grid = XMBCoreRenderer.makeGrid(resolution: 100)
        guard let vertexBuffer = device.makeBuffer(bytes: grid.vertices,
                                                   length: MemoryLayout<SIMD2<Float>>.stride * grid.vertices.count,
                                                   options: .storageModeShared),
              let indexBuffer = device.makeBuffer(bytes: grid.indices,
                                                  length: MemoryLayout<UInt16>.stride * grid.indices.count,
                                                  options: .storageModeShared) else {
            fatalError("Could not create wave grid buffers")
        }
        gridVertexBuffer = vertexBuffer
        gridIndexBuffer = indexBuffer
        gridIndexCount = grid.indices.count

        rebuildSeedsIfNeeded()
    }

    func setAntiAliasing(_ mode: AntiAliasingMode) {
        let effective = AntiAliasingMode.supported(mode)
        guard effective != antiAliasing else { return }
        antiAliasing = effective
        pipelines = shared.pipelines(for: effective.sampleCount)
    }

    func update(variant: XMBVariant) {
        let changed = variant.id != self.variant.id
        self.variant = variant
        if changed {
            splinePipeline.resetTemporalState()
            rebuildSeedsIfNeeded()
        } else {
            rebuildSeedsIfNeeded()
        }
    }

    func render(time: Float, aspect: Float, descriptor: MTLRenderPassDescriptor,
                commandBuffer: MTLCommandBuffer, viewport: CGSize) {
        let params = variant.parameters
        splinePipeline.update(settings: params, time: time)
        let width = SplinePipeline.splineWidth
        let height = SplinePipeline.splineHeight
        splinePipeline.displacement.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                splineTexture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: width * MemoryLayout<Float>.stride
                )
            }
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(viewport.width),
                                        height: Double(viewport.height),
                                        znear: 0, zfar: 1))

        drawBackground(encoder: encoder)
        drawWave(encoder: encoder, time: time)
        if params.particleCount > 0 {
            drawParticles(encoder: encoder, time: time, aspect: aspect)
        }

        encoder.endEncoding()
    }

    private func drawBackground(encoder: MTLRenderCommandEncoder) {
        let gradient = variant.gradient
        let range = gradient.tRange
        let start = gradient.start.simd
        let end = gradient.end.simd
        let dir = gradient.direction
        let uniforms: [Float] = [
            start.x, start.y, start.z,
            end.x, end.y, end.z,
            dir.x, dir.y,
            range.min, range.span,
        ]

        encoder.setRenderPipelineState(pipelines.background)
        backgroundBuffer.withUnsafeContents { ptr in
            encoder.setVertexBytes(ptr, length: 32, index: 0)
        }
        uniforms.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                encoder.setFragmentBytes(base, length: raw.count, index: 0)
            }
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func drawWave(encoder: MTLRenderCommandEncoder, time: Float) {
        let p = variant.parameters
        let uniforms: [Float] = [
            time, p.flowSpeed, p.tension, p.damping, p.length, p.spacing,
            p.perturbation, p.perturbationScale, p.timeStep, p.waveCosAmp,
            p.waveBias, p.waveHeightScale, p.waveSoftClip, p.ffdYAmp, p.ffdZAmp,
            p.zDetailScale,
            p.ffdScale1X, p.ffdScale1Y, p.ffdScale1Z,
            p.ffdScale2X, p.ffdScale2Y, p.ffdScale2Z,
            p.ffdOffsetX, p.ffdOffsetY, p.ffdOffsetZ,
        ]
        let fragmentUniforms: [Float] = [
            p.opacity, p.brightness, p.fresnelPower, p.fresnelScale,
        ]

        encoder.setRenderPipelineState(pipelines.wave)
        encoder.setVertexBuffer(gridVertexBuffer, offset: 0, index: 0)
        uniforms.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                encoder.setVertexBytes(base, length: raw.count, index: 1)
            }
        }
        encoder.setVertexTexture(splineTexture, index: 0)
        fragmentUniforms.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                encoder.setFragmentBytes(base, length: raw.count, index: 0)
            }
        }
        encoder.drawIndexedPrimitives(
            type: .triangleStrip,
            indexCount: gridIndexCount,
            indexType: .uint16,
            indexBuffer: gridIndexBuffer,
            indexBufferOffset: 0
        )
    }

    private func drawParticles(encoder: MTLRenderCommandEncoder, time: Float, aspect: Float) {
        guard let seedBuffer else { return }
        let p = variant.parameters
        let ratio = max(1.0, min(aspect, 2.0)) * 0.375
        let uniforms: [Float] = [
            time, p.particleFlowSpeed, ratio, p.particleOpacity,
            p.particleSizeBase, p.particleSizeVar,
        ]

        encoder.setRenderPipelineState(pipelines.particle)
        encoder.setVertexBuffer(seedBuffer, offset: 0, index: 0)
        uniforms.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                encoder.setVertexBytes(base, length: raw.count, index: 1)
            }
        }
        uniforms.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                encoder.setFragmentBytes(base, length: raw.count, index: 0)
            }
        }
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: seedCount)
    }

    private func rebuildSeedsIfNeeded() {
        let count = max(0, variant.parameters.particleCount)
        guard count != seedCount || variant.id != seedVariantID else { return }
        seedCount = count
        seedVariantID = variant.id
        guard count > 0 else {
            seedBuffer = nil
            return
        }

        var rng = SplitMix64(seed: UInt64(truncatingIfNeeded: stableHash(variant.id)))
        var seeds = [SIMD3<Float>](repeating: .zero, count: count)
        for i in 0..<count {
            let x = Float.random(in: 0..<1, using: &rng)
            let y = Float.random(in: 0..<1, using: &rng)
            let z = powf(Float.random(in: 0..<1, using: &rng), 8) + 0.1
            seeds[i] = SIMD3<Float>(x, y, z)
        }
        seedBuffer = shared.device.makeBuffer(
            bytes: seeds,
            length: MemoryLayout<SIMD3<Float>>.stride * count,
            options: .storageModeShared
        )
    }

    private static func makeGrid(resolution: Int) -> (vertices: [SIMD2<Float>], indices: [UInt16]) {
        let strips = resolution - 1
        let vertsPerStrip = resolution * 2
        var vertices = [SIMD2<Float>]()
        vertices.reserveCapacity(strips * vertsPerStrip)
        for y in 0..<strips {
            for x in 0..<resolution {
                let fx = (Float(x) / Float(resolution - 1)) * 2 - 1
                let topY = (Float(y + 1) / Float(resolution - 1)) * 2 - 1
                let bottomY = (Float(y) / Float(resolution - 1)) * 2 - 1
                vertices.append(SIMD2<Float>(fx, topY))
                vertices.append(SIMD2<Float>(fx, bottomY))
            }
        }

        var indices = [UInt16]()
        indices.reserveCapacity(strips * (vertsPerStrip + 2) - 2)
        var base = 0
        for s in 0..<strips {
            if s > 0 {
                indices.append(UInt16(base - 1))
                indices.append(UInt16(base))
            }
            for i in 0..<vertsPerStrip {
                indices.append(UInt16(base + i))
            }
            base += vertsPerStrip
        }
        return (vertices, indices)
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private func stableHash(_ string: String) -> Int {
    var hash: UInt64 = 1469598103934665603
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1099511628211
    }
    return Int(bitPattern: UInt(truncatingIfNeeded: hash))
}

private extension MTLBuffer {
    func withUnsafeContents(_ body: (UnsafeRawPointer) -> Void) {
        body(contents())
    }
}
