//
//  Uniforms.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import simd

struct Uniforms {
    var modelViewProjectionMatrix: matrix_float4x4
    var dashLength: Float
}

class Camera {
    var position: SIMD3<Float> = [0, 0, 150]
    var target: SIMD3<Float> = [0, 0, 0]
    var up: SIMD3<Float> = [0, 1, 0]
    
    var fov: Float = 45.0 * (.pi / 180.0)
    var aspectRatio: Float = 1.0
    var nearZ: Float = 0.1
    var farZ: Float = 1000.0
    
    var rotation: SIMD2<Float> = [0, 0] // pitch, yaw
    var distance: Float = 150.0

    func updateMatrix() -> matrix_float4x4 {
        let pitch = simd_quaternion(rotation.x, SIMD3<Float>(1, 0, 0))
        let yaw = simd_quaternion(rotation.y, SIMD3<Float>(0, 1, 0))
        let rotDict = simd_mul(yaw, pitch)
        
        let eye = target + simd_act(rotDict, SIMD3<Float>(0, 0, distance))
        let view = matrix_look_at(eye: eye, target: target, up: up)
        let proj = matrix_perspective(fovY: fov, aspect: aspectRatio, nearZ: nearZ, farZ: farZ)
        
        return simd_mul(proj, view)
    }

    private func matrix_look_at(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
        let z = simd_normalize(eye - target)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        
        let t = SIMD3<Float>(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye))
        
        return matrix_float4x4(
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1)
        )
    }

    private func matrix_perspective(fovY: Float, aspect: Float, nearZ: Float, farZ: Float) -> matrix_float4x4 {
        let yScale = 1 / tan(fovY * 0.5)
        let xScale = yScale / aspect
        let zScale = farZ / (nearZ - farZ)
        let zOffset = (nearZ * farZ) / (nearZ - farZ)

        return matrix_float4x4(
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -1),
            SIMD4<Float>(0, 0, zOffset, 0)
        )
    }
}
