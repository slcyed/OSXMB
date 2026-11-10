import Foundation

/// CPU-side port of the reverse-engineered spline displacement pipeline.
/// This mirrors ps3xmbwave/spline-reverse.js from the MIT-licensed
/// PlayStation-3-XMB project and feeds a 256 x 64 float texture to Metal.
final class SplinePipeline {
    static let tableEntryCount = 0x169
    static let loopIters = 8
    static let tableSize = 0x2200
    static let splineWidth = 256
    static let splineHeight = 64
    static let controlPointCount = 28

    private static let normA: [Float] = [0.39584, -0.0052389996, -0.58664495, 0.189007]
    private static let normB: [Float] = [-0.003751, -0.57536095, 0.161975, 0.417137]
    private static let r37Words = [0x00, 0x11, 0x22, 0x33]

    private var b380 = [UInt8](repeating: 0, count: tableSize)
    private var lastSeed = Int.min
    private var coeffs = [Float](repeating: 0, count: tableEntryCount * 16)
    private var table = [Float](repeating: 0, count: tableEntryCount * 4)
    private var kernelPacked = [Float](repeating: 0, count: loopIters * 8 * 4)
    private var kernelPackedPrev = [Float](repeating: 0, count: loopIters * 8 * 4)
    private var controlPoints = [Float](repeating: 0, count: controlPointCount)
    private(set) var displacement = [Float](repeating: 0, count: splineWidth * splineHeight)

    func update(settings: XMBParameters, time: Float) {
        let b300 = buildB300(settings)
        buildB380IfNeeded(settings)
        decodeCoefficients(settings: settings, time: time)
        buildSplineTable(b300: b300, settings: settings)
        runKernel(settings: settings, time: time)
        writeDisplacementTexture(settings: settings, time: time)
    }

    private func buildB300(_ s: XMBParameters) -> [Float] {
        [
            s.damping, s.length, s.tension, s.spacing * 0.001,
            s.waveCosAmp, s.waveBias, s.timeStep, s.perturbation,
            s.perturbationScale, s.flowSpeed, s.ffdScale1X, s.ffdScale2X,
            s.ffdOffsetY, s.fresnelScale, s.waveHeightScale, 1.0,
        ]
    }

    private func buildB380IfNeeded(_ settings: XMBParameters) {
        let seed = settings.reSyntheticDescriptorSeed
        guard seed != lastSeed else { return }
        lastSeed = seed

        let len = Self.tableSize
        for i in 0..<len {
            let f = Float(i) / Float(len)
            let wave =
                sinf((f * 97.0) * (0.3 + settings.length)) * 0.5 +
                sinf((f * 211.0) * (0.15 + settings.tension * 3.0)) * 0.3 +
                sinf((f * 17.0) * (0.2 + settings.perturbationScale * 2.0)) * 0.2
            let noise = Float(hash01(Double(i) * 13.37 + Double(seed) * 0.01)) * 2.0 - 1.0
            let v = clamp01((wave * settings.reDescriptorStrength + noise * 0.35 + 1.0) * 0.5)
            b380[i] = UInt8(v * 255)
        }
    }

    private func decodeCoefficients(settings: XMBParameters, time: Float) {
        let len = Self.tableSize
        let phase = time * settings.flowSpeed * settings.timeStep * settings.reSyntheticDescriptorMotion

        for entry in 0..<Self.tableEntryCount {
            let entryBase = entry * 16
            let descBase = (entry * 0x130) % len
            let entryPhase = Float(entry) * 0.07
            for blk in 0..<4 {
                let blkPhase = Float(blk) * 0.91
                for lane in 0..<4 {
                    let byteIdx = (descBase + blk * 0x10 + lane * 4 + (entry % 7)) % len
                    let b = Float(b380[byteIdx]) / 255.0
                    let centered = b * 2.0 - 1.0
                    let harmonic = sinf(entryPhase + blkPhase + Float(lane) * 1.37 + phase * 0.23)
                    coeffs[entryBase + blk * 4 + lane] = centered * 0.75 + harmonic * 0.25
                }
            }
        }
    }

    private func buildSplineTable(b300: [Float], settings: XMBParameters) {
        let gain = settings.reNormalizeGain
        for i in 0..<Self.tableEntryCount {
            let cBase = i * 16
            let tBase = i * 4
            for lane in 0..<4 {
                let raw =
                    coeffs[cBase + lane] * b300[0] +
                    coeffs[cBase + 4 + lane] * b300[1] +
                    coeffs[cBase + 8 + lane] * b300[2] +
                    coeffs[cBase + 12 + lane] * b300[3]

                let denomAbs = max(abs(Self.normB[lane]), 0.05)
                let denom = Self.normB[lane] < 0 ? -denomAbs : denomAbs
                let norm = ((raw - Self.normA[lane]) / denom) * gain
                table[tBase + lane] = tanhf(norm)
            }
        }
    }

    private func runKernel(settings: XMBParameters, time: Float) {
        for iter in 0..<Self.loopIters {
            let phase = time * settings.reKernelPhaseStep + Float(iter) * 0.37

            var idxFloat = [Float](repeating: 0, count: 4)
            for lane in 0..<4 {
                let baseWord = (Self.r37Words[lane] + iter * 0x13) & 0xff
                let baseIdx = Self.tableIndexFromWord(baseWord)
                let offset = sinf(phase + Float(lane) * 0.77) * settings.reIndexJitter * Float(Self.tableEntryCount)
                idxFloat[lane] = Self.wrapIndexFloat(Float(baseIdx) + offset, Float(Self.tableEntryCount))
            }

            let v0 = sampleTable(idxFloat[0])
            let v1 = sampleTable(idxFloat[1])
            let v2 = sampleTable(idxFloat[2])
            let v3 = sampleTable(idxFloat[3])

            let mixA = 0.5 + 0.5 * sinf(phase * 0.7)
            let mixB = 0.5 + 0.5 * cosf(phase * 0.9)

            let r12 = mix4(v0, v1, mixA)
            let r13 = mix4(v1, v2, mixB)
            let r14 = mix4(v2, v3, mixA)
            let r15 = mix4(v3, v0, mixB)
            let r9 = sub4(v1, v0)
            let r4 = sub4(v2, v1)
            let r87 = sub4(v3, v2)
            let r89 = sub4(v0, v3)

            let stores = [r12, r13, r14, r15, r9, r4, r87, r89]
            for s in 0..<8 {
                let packedBase = (iter * 8 + s) * 4
                let v = stores[s]
                kernelPacked[packedBase] = v.0
                kernelPacked[packedBase + 1] = v.1
                kernelPacked[packedBase + 2] = v.2
                kernelPacked[packedBase + 3] = v.3
            }
        }

        let temporal = min(max(settings.reTemporalSmooth, 0), 0.999)
        for i in 0..<kernelPacked.count {
            let smoothed = kernelPackedPrev[i] * temporal + kernelPacked[i] * (1.0 - temporal)
            kernelPacked[i] = smoothed
            kernelPackedPrev[i] = smoothed
        }
    }

    private func writeDisplacementTexture(settings: XMBParameters, time: Float) {
        let width = Self.splineWidth
        let height = Self.splineHeight
        let cpCount = Self.controlPointCount
        let kernelVecCount = Self.loopIters * 8
        let flow = time * settings.flowSpeed * settings.timeStep
        let pi = Float.pi

        for row in 0..<height {
            let z = (Float(row) / Float(max(1, height - 1))) * 2.0 - 1.0
            let rowBase = row * width
            let rowPhase = flow * 0.25 + z * 1.7

            for i in 0..<cpCount {
                let x = Float(i) / Float(max(1, cpCount - 1))
                let kvf = Float(row) * 0.93 + Float(i) * 0.61 + flow * 0.35
                let kvFloor = floorf(kvf)
                let kv0 = ((Int(kvFloor) % kernelVecCount) + kernelVecCount) % kernelVecCount
                let kv1 = (kv0 + 1) % kernelVecCount
                let kt = kvf - kvFloor

                let k0 = kv0 * 4
                let k1 = kv1 * 4
                let kx = kernelPacked[k0] * (1.0 - kt) + kernelPacked[k1] * kt
                let ky = kernelPacked[k0 + 1] * (1.0 - kt) + kernelPacked[k1 + 1] * kt
                let kz = kernelPacked[k0 + 2] * (1.0 - kt) + kernelPacked[k1 + 2] * kt
                let kw = kernelPacked[k0 + 3] * (1.0 - kt) + kernelPacked[k1 + 3] * kt

                let reCore =
                    (kx * 0.45 + ky * 0.25 + kz * 0.2 + kw * 0.1) * settings.reKernelGain +
                    sinf(rowPhase + x * 6.2) * settings.bandAmplitude +
                    cosf(z * settings.bandSecondaryFreq + x * 4.8 + flow * 0.09) * settings.bandSecondaryAmp

                let legacy =
                    sinf((x * pi * 1.3 + z * 0.8) - flow * settings.travelSpeed1) * settings.travelAmp1 * settings.tension +
                    sinf((x * pi * 2.8 - z * 1.2) + flow * settings.travelSpeed2) * settings.travelAmp2 +
                    settings.perturbation * settings.perturbationScale *
                        sinf((x * (4.0 + settings.length * 2.0) + z * 4.0 - flow * 0.6) * (settings.spacing * 0.01))

                controlPoints[i] = reCore * settings.rePipelineBlend + legacy * (1.0 - settings.rePipelineBlend)
            }

            for xi in 0..<width {
                displacement[rowBase + xi] = evalSpline(controlPoints, Float(xi) / Float(max(1, width - 1)))
            }
        }
    }

    private func sampleTable(_ idxFloat: Float) -> (Float, Float, Float, Float) {
        let len = Self.tableEntryCount
        let f = floorf(idxFloat)
        let i0 = (Int(f) % len + len) % len
        let i1 = (i0 + 1) % len
        let t = idxFloat - f
        let b0 = i0 * 4
        let b1 = i1 * 4
        return (
            table[b0] * (1 - t) + table[b1] * t,
            table[b0 + 1] * (1 - t) + table[b1 + 1] * t,
            table[b0 + 2] * (1 - t) + table[b1 + 2] * t,
            table[b0 + 3] * (1 - t) + table[b1 + 3] * t
        )
    }

    private func mix4(_ a: (Float, Float, Float, Float),
                      _ b: (Float, Float, Float, Float),
                      _ t: Float) -> (Float, Float, Float, Float) {
        let s = 1 - t
        return (a.0 * s + b.0 * t, a.1 * s + b.1 * t,
                a.2 * s + b.2 * t, a.3 * s + b.3 * t)
    }

    private func sub4(_ a: (Float, Float, Float, Float),
                      _ b: (Float, Float, Float, Float)) -> (Float, Float, Float, Float) {
        (a.0 - b.0, a.1 - b.1, a.2 - b.2, a.3 - b.3)
    }

    private func evalSpline(_ cp: [Float], _ u: Float) -> Float {
        let n = cp.count - 3
        guard n >= 1 else { return 0 }
        var s = u * Float(n)
        s = max(0, min(s, Float(n) - 1e-6))
        let seg = Int(floorf(s))
        let t = s - Float(seg)
        let t2 = t * t
        let t3 = t2 * t
        let b0 = (1 - 3 * t + 3 * t2 - t3) / 6
        let b1 = (4 - 6 * t2 + 3 * t3) / 6
        let b2 = (1 + 3 * t + 3 * t2 - 3 * t3) / 6
        let b3 = t3 / 6
        return b0 * cp[seg] + b1 * cp[seg + 1] + b2 * cp[seg + 2] + b3 * cp[seg + 3]
    }

    private static func tableIndexFromWord(_ word: Int) -> Int {
        let hi = (word >> 4) & 0xff
        let lo = word & 0xf
        return (19 * hi + lo) % tableEntryCount
    }

    private static func wrapIndexFloat(_ v: Float, _ len: Float) -> Float {
        var out = v.truncatingRemainder(dividingBy: len)
        if out < 0 { out += len }
        return out
    }
}

private func clamp01(_ v: Float) -> Float { max(0, min(1, v)) }

private func hash01(_ x: Double) -> Double {
    let v = sin(x) * 43758.5453123
    return v - floor(v)
}

extension SplinePipeline {
    func resetTemporalState() {
        for i in kernelPackedPrev.indices { kernelPackedPrev[i] = 0 }
        for i in kernelPacked.indices { kernelPacked[i] = 0 }
    }
}
