import Foundation
import simd

struct ReefTriangle {
    let a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>
    var clearance: Float = 0
    var normal: SIMD3<Float> {
        let n = simd_cross(b - a, c - a)
        return simd_length_squared(n) > 1e-10 ? simd_normalize(n) : SIMD3(0, 1, 0)
    }
    func closest(to p: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = p - b, d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + ab * (d1 / max(d1 - d3, 1e-9)) }
        let cp = p - c, d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + ac * (d2 / max(d2 - d6, 1e-9)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0 { return b + (c - b) * ((d4 - d3) / max(d4 - d3 + d5 - d6, 1e-9)) }
        let denominator = va + vb + vc
        if abs(denominator) < 1e-10 { return a }
        return a + ab * (vb / denominator) + ac * (vc / denominator)
    }
}

struct Cell: Hashable { let x: Int, y: Int, z: Int }
final class ReefCollider {
    let triangles: [ReefTriangle]
    let maximumClearance: Float
    private var cells: [Cell: [Int]] = [:]
    init(points: [[Float]], margins: [Float] = []) {
        maximumClearance = margins.max() ?? 0
        triangles = stride(from: 0, to: points.count - 2, by: 3).map { i in
            func v(_ j: Int) -> SIMD3<Float> { SIMD3(points[j][0], points[j][1], points[j][2]) }
            return ReefTriangle(a: v(i), b: v(i + 1), c: v(i + 2), clearance: margins.indices.contains(i / 3) ? margins[i / 3] : 0)
        }
        for (i, t) in triangles.enumerated() {
            let lo = simd_min(t.a, simd_min(t.b, t.c)), hi = simd_max(t.a, simd_max(t.b, t.c))
            for x in Int(floor(lo.x))...Int(floor(hi.x)) {
                for y in Int(floor(lo.y))...Int(floor(hi.y)) {
                    for z in Int(floor(lo.z))...Int(floor(hi.z)) { cells[Cell(x: x, y: y, z: z), default: []].append(i) }
                }
            }
        }
    }
    func contact(_ p: SIMD3<Float>, radius: Float) -> (normal: SIMD3<Float>, distance: Float)? {
        var candidates = Set<Int>()
        let searchRadius = radius + maximumClearance
        for x in Int(floor(p.x - searchRadius))...Int(floor(p.x + searchRadius)) {
            for y in Int(floor(p.y - searchRadius))...Int(floor(p.y + searchRadius)) {
                for z in Int(floor(p.z - searchRadius))...Int(floor(p.z + searchRadius)) { candidates.formUnion(cells[Cell(x: x, y: y, z: z)] ?? []) }
            }
        }
        var best: (SIMD3<Float>, Float)?
        for i in candidates.sorted() {
            let t = triangles[i], delta = p - t.closest(to: p), distance = simd_length(delta)
            let effective = distance - t.clearance
            if effective < radius && effective < (best?.1 ?? .greatestFiniteMagnitude) { best = (distance > 1e-5 ? delta / distance : t.normal, effective) }
        }
        return best
    }
}

struct Swimmer {
    let species: Int
    let scale: Float
    let radius: Float
    let phase: Float
    let cruise: Float
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var heading: Float
    var bank: Float = 0
}

struct FishProfile: Decodable { let spawnScale: Float; let collisionRadius: Float }
enum TankSimulationError: Error { case noClearSpawn(Int) }

final class TankSimulation {
    let collider: ReefCollider
    let lower = SIMD3<Float>(-6.9, -1.65, -1.65)
    let upper = SIMD3<Float>(6.9, 4.1, 5.2)
    private(set) var swimmers: [Swimmer] = []
    private(set) var time: Float = 0
    private(set) var unresolvedContacts = 0
    init(collider: ReefCollider, profiles: [FishProfile], speciesIndices: [Int]? = nil) throws {
        self.collider = collider
        // A deterministic 3-D candidate grid spreads every species across depth
        // and height. Reject reef intersections and overlapping initial spheres.
        var candidates: [SIMD3<Float>] = []
        for z in 0..<5 { for y in 0..<6 { for x in 0..<13 {
            candidates.append(SIMD3(Float(x) - 6, -0.6 + Float(y) * 0.8, -0.8 + Float(z) * 1.2))
        } } }
        for (i, profile) in profiles.enumerated() {
            let radius = profile.collisionRadius
            var best: SIMD3<Float>?, bestScore: Float = -.greatestFiniteMagnitude
            for candidate in candidates {
                guard (0..<3).allSatisfy({ candidate[$0] >= lower[$0] + radius && candidate[$0] <= upper[$0] - radius }),
                      collider.contact(candidate, radius: radius + 0.06) == nil else { continue }
                let separation = swimmers.map { simd_distance(candidate, $0.position) / (radius + $0.radius + 0.12) }.min()
                guard separation == nil || separation! >= 1 else { continue }
                let score = separation ?? -simd_distance(candidate, SIMD3(-3, 2.4, 3.6))
                if score > bestScore { best = candidate; bestScore = score }
            }
            guard let p = best else { throw TankSimulationError.noClearSpawn(i) }
            let speed: Float = 0.32 + Float(i % 5) * 0.04
            let sign: Float = i % 2 == 0 ? -1 : 1
            let depthSpeed = Float(i % 3 - 1) * 0.12
            let velocity = SIMD3<Float>(sign * speed, 0, depthSpeed)
            swimmers.append(Swimmer(species: speciesIndices?[i] ?? i, scale: profile.spawnScale, radius: radius, phase: Float(i) * 1.73, cruise: speed, position: p, velocity: velocity, heading: atan2(depthSpeed, -velocity.x)))
        }
    }

    static func angleDelta(_ target: Float, _ current: Float) -> Float { atan2(sin(target - current), cos(target - current)) }

    func step(_ dt: Float) {
        let dt = min(max(dt, 0), 1 / 30)
        guard dt > 0 else { return }
        time += dt
        let previous = swimmers
        for i in swimmers.indices {
            var fish = previous[i]
            let p = fish.position, phase = fish.phase
            var acceleration = SIMD3<Float>(sin(time * 0.21 + phase) * 0.09, sin(time * 0.33 + phase) * 0.06, cos(time * 0.27 + phase) * 0.10)
            // A slowly moving home region keeps depth and height varied without fixed loops.
            let home = SIMD3<Float>(sin(time * 0.055 + phase) * 4.8, 1.3 + sin(time * 0.1 + phase) * 1.5, 2.2 + cos(time * 0.07 + phase) * 2.2)
            acceleration += (home - p) * SIMD3(0.018, 0.065, 0.042)
            for axis in 0..<3 {
                let margin: Float = fish.radius + 0.9
                if p[axis] < lower[axis] + margin { acceleration[axis] += (lower[axis] + margin - p[axis]) * 0.7 }
                if p[axis] > upper[axis] - margin { acceleration[axis] -= (p[axis] - upper[axis] + margin) * 0.7 }
            }
            for (j, other) in previous.enumerated() where j != i {
                let delta = p - other.position, distance = simd_length(delta), safe = fish.radius + other.radius + 0.45
                if distance < safe && distance > 1e-4 { acceleration += delta / distance * (safe - distance) * 1.1 }
                let relative = fish.velocity - other.velocity
                let encounter = min(2.5, max(0, -simd_dot(delta, relative) / max(0.001, simd_length_squared(relative))))
                let projected = delta + relative * encounter, gap = simd_length(projected)
                if encounter > 0.05 && gap < safe {
                    let away = gap > 0.02 ? projected / gap : simd_normalize(SIMD3(-fish.velocity.z, 0.05, fish.velocity.x))
                    acceleration += away * (safe - gap) * 0.65
                }
            }
            let forward = p + fish.velocity * 1.15
            if let hit = collider.contact(forward, radius: fish.radius + 0.35) { acceleration += hit.normal * (fish.radius + 0.35 - hit.distance) * 1.8 }
            let maxAcceleration: Float = 0.65
            if simd_length(acceleration) > maxAcceleration { acceleration = simd_normalize(acceleration) * maxAcceleration }
            var velocity = fish.velocity + acceleration * dt
            velocity.y = min(0.16, max(-0.16, velocity.y))
            let speed = simd_length(velocity)
            if speed > fish.cruise * 1.3 { velocity *= fish.cruise * 1.3 / speed }
            if speed < fish.cruise * 0.5 && speed > 1e-5 { velocity *= fish.cruise * 0.5 / speed }
            var next = p + velocity * dt
            for _ in 0..<12 {
                guard let hit = collider.contact(next, radius: fish.radius + 0.035) else { break }
                next += hit.normal * (fish.radius + 0.04 - hit.distance)
                let inward = simd_dot(velocity, hit.normal)
                if inward < 0 { velocity -= inward * hit.normal }
            }
            next = simd_clamp(next, lower + fish.radius, upper - fish.radius)
            if collider.contact(next, radius: fish.radius) != nil {
                // Preserve last known clear position rather than tunnel through a mesh.
                next = p; velocity = SIMD3(-fish.velocity.z, 0.05, fish.velocity.x) * 0.75
                unresolvedContacts += 1
            }
            let target = atan2(velocity.z, -velocity.x)
            let turn = Self.angleDelta(target, fish.heading)
            let maximumTurn: Float = 0.8 * dt
            fish.heading += min(maximumTurn, max(-maximumTurn, turn))
            fish.bank += (min(0.11, max(-0.11, turn * 0.12)) - fish.bank) * min(1, dt * 2)
            fish.position = next; fish.velocity = velocity
            swimmers[i] = fish
        }
    }
    func synchronizeClock(to value: Float) { time = value }
    func advance(to target: Float) { while time + 1 / 60 <= target { step(1 / 60) } }
}
