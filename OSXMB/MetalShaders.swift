import Foundation

enum MetalShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct BGVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex BGVertexOut bgVertex(uint vid [[vertex_id]],
                                constant float2* verts [[buffer(0)]]) {
        float2 p = verts[vid];
        BGVertexOut out;
        out.position = float4(p, 0.0, 1.0);
        out.uv = float2(p.x * 0.5 + 0.5, 1.0 - (p.y * 0.5 + 0.5));
        return out;
    }

    fragment float4 bgFragment(BGVertexOut in [[stage_in]],
                               constant float* u [[buffer(0)]]) {
        float3 colorStart = float3(u[0], u[1], u[2]);
        float3 colorEnd = float3(u[3], u[4], u[5]);
        float2 dir = float2(u[6], u[7]);
        float tMin = u[8];
        float tSpan = u[9];
        float t = dot(in.uv, dir);
        float a = clamp((t - tMin) / max(tSpan, 1e-6), 0.0, 1.0);
        float g = a * a * (3.0 - 2.0 * a);
        return float4(mix(colorStart, colorEnd, g), 1.0);
    }

    struct WaveVertexOut {
        float4 position [[position]];
        float3 vPos;
    };

    vertex WaveVertexOut waveVertex(uint vid [[vertex_id]],
                                    constant float2* verts [[buffer(0)]],
                                    constant float* u [[buffer(1)]],
                                    texture2d<float> splineTex [[texture(0)]]) {
        constexpr sampler splineSampler(coord::normalized,
                                        address::clamp_to_edge,
                                        filter::linear);
        float2 aPos = verts[vid];
        float3 p = float3(aPos.x, 0.0, aPos.y);
        float2 uv = (aPos + 1.0) * 0.5;
        p.y = splineTex.sample(splineSampler, uv).r;

        float3 ffd1 = p * float3(u[16], u[17], u[18]) + float3(u[22], u[23], u[24]);
        float3 ffd2 = p * float3(u[19], u[20], u[21]) + float3(u[22], u[23], u[24]);
        p.y += sin(ffd1.x + u[0] * u[1]) * u[13];
        p.z += cos(ffd2.z + u[0] * u[1]) * u[14];

        float baseWave = cos(p.x * 2.0 - u[0] * 0.5 * u[8]) * u[9] + u[10];
        baseWave *= (1.0 - u[3]);
        baseWave += u[2] * sin(p.x * u[4] + u[0] * u[1] * u[8] * 0.25);

        float structured = u[6] * u[7] * (
            sin((p.x * u[4] * 6.0 + p.z * 0.5) * u[5] * 0.01 + u[0] * u[1] * u[8] * 0.7) * 0.5 +
            sin((p.x * u[4] * 10.0 - p.z * 0.8) * u[5] * 0.005 - u[0] * u[1] * u[8] * 0.35) * 0.25
        );

        float totalWave = (baseWave + structured) * u[11];
        totalWave = u[12] * tanh(totalWave / max(u[12], 1e-4));
        p.y -= totalWave;

        float2 uv2 = uv;
        uv2.x = fract(uv2.x - u[0] * u[1] * 0.04 * u[8]);
        p.z -= splineTex.sample(splineSampler, uv2).r * u[15];

        WaveVertexOut out;
        out.position = float4(p, 1.0);
        out.vPos = p;
        return out;
    }

    fragment float4 waveFragment(WaveVertexOut in [[stage_in]],
                                 constant float* u [[buffer(0)]]) {
        float3 dx = dfdx(in.vPos);
        float3 dy = dfdy(in.vPos);
        float3 n = normalize(cross(dy, dx));
        float fresnel = u[3] * pow(1.0 + dot(float3(0.0, 0.0, -1.0), n), u[2]);
        return float4(1.0, 1.0, 1.0, fresnel * u[0] * u[1]);
    }

    struct ParticleVertexOut {
        float4 position [[position]];
        float point_size [[point_size]];
        float alpha;
    };

    vertex ParticleVertexOut particleVertex(uint vid [[vertex_id]],
                                            constant float3* seeds [[buffer(0)]],
                                            constant float* u [[buffer(1)]]) {
        float3 a = seeds[vid];
        float time = u[0] * u[1];
        float ratio = u[2];

        float x = fract(time * (a.x - 0.5) / 15.0 + a.y * 50.0) * 2.0 - 1.0;
        float y = sin(sign(a.y) * time * (a.y + 1.5) / 4.0 + a.x * 100.0)
                / ((6.0 - a.x * 4.0 * a.y) / ratio);
        float opVar = mix(
            sin(time * (a.x + 0.5) * 12.0 + a.y * 10.0),
            sin(time * (a.y + 1.5) * 6.0 + a.x * 4.0),
            y * 0.5 + 0.5) * a.x + a.y;
        float alpha = opVar * opVar * (1.0 - fract(a.x + time * 0.00285));

        ParticleVertexOut out;
        out.position = float4(x, y, 0.0, 1.0);
        out.point_size = a.z * u[5] + u[4];
        out.alpha = alpha;
        return out;
    }

    fragment float4 particleFragment(ParticleVertexOut in [[stage_in]],
                                     float2 pointCoord [[point_coord]],
                                     constant float* u [[buffer(0)]]) {
        float2 c = pointCoord * 2.0 - 1.0;
        float d = dot(c, c);
        if (d > 1.0) {
            discard_fragment();
        }
        float sparkle = (1.0 - d) * (1.0 - d);
        float a = in.alpha * u[3] * sparkle;
        return float4(a, a, a, 1.0);
    }
    """
}
