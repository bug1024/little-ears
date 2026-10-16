import Foundation
import simd

enum AquariumError: Error { case unavailable(String) }

func rotation(yaw: Float, pitch: Float) -> simd_float4x4 {
    let y = simd_float4x4(columns: (SIMD4(cos(yaw), 0, -sin(yaw), 0), SIMD4(0, 1, 0, 0), SIMD4(sin(yaw), 0, cos(yaw), 0), SIMD4(0, 0, 0, 1)))
    let x = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, cos(pitch), sin(pitch), 0), SIMD4(0, -sin(pitch), cos(pitch), 0), SIMD4(0, 0, 0, 1)))
    return x * y
}
