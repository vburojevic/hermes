import CoreGraphics
import Foundation

/// A face's steady motion as keyframes (`docs/bot-faces.md` §5): the sway, breath, glances,
/// blinks and dots of one mood, sampled from `FacePose` and thinned to the points that matter.
/// Core Animation plays them in the render server, so a face that only does its mood's motion
/// costs the app nothing per frame; a `TimelineView` redrawing a `Canvas` committed the whole
/// window every frame.
///
/// A face's motion repeats every `FaceTarget.period` seconds of the face clock, so one loop serves
/// at any time: played `t mod period` seconds in, it shows what a drawn face shows at `t`.
public struct FaceLoop: Sendable, Equatable {
    /// One animated value: `keyTimes` (0…1 across the loop) and a value at each, linear between.
    /// A discrete track has one more key time than values, as Core Animation's discrete mode wants.
    public struct Track: Sendable, Equatable {
        public var keyTimes: [Double]
        public var values: [Double]

        /// Every key holds the same value: set it, nothing to animate.
        public var constant: Double? {
            guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
            return first
        }
    }

    public var duration: Double
    /// Degrees, about the bottom of the body.
    public var lean: Track
    /// The body's scale about its bottom: taller on the in-breath, a touch narrower.
    public var scaleX: Track
    public var scaleY: Track
    /// The eyes' midpoint in face units: the body's eye line plus the gaze, kept on the body.
    public var eyesX: Track
    public var eyesY: Track
    /// The open eyes' height against `eyeHeight` (the eyelids).
    public var lid: Track
    /// Discrete, 1 or 0: the eyes draw open (else as the closed stroke), and show a catchlight.
    public var open: Track
    public var catchlight: Track
    /// The three dots' opacities.
    public var dots: [Track]
    /// The open eyes' half-height in face units: 2.6 for the busy and listening moods, else 2.3.
    public var eyeHeight: Double

    /// The loop for `target` on `shape`. `stilled` is Reduce Motion's pose (blinks and dots only).
    /// Faces under 24 pt draw no catchlight, as the painter.
    public static func make(_ target: FaceTarget, shape: FaceShape, pointSize: Double, stilled: Bool = false, rate: Double = 60) -> FaceLoop {
        let body = FaceBody.of(shape)
        let mood = target.mood
        let eyeHeight = mood.isBusy || mood == .listening ? 2.6 : 2.3
        let duration = FaceTarget.period
        let count = max(2, Int((duration * rate).rounded()))

        var times: [Double] = [], lean: [Double] = [], scaleX: [Double] = [], scaleY: [Double] = []
        var eyesX: [Double] = [], eyesY: [Double] = [], lid: [Double] = []
        var open: [Double] = [], catchlight: [Double] = [], dots: [[Double]] = [[], [], []]
        for index in 0...count {
            let into = duration * Double(index) / Double(count)
            // The last sample is the period's end, which is its start again.
            var p = target.pose(at: index == count ? 0 : into)
            if stilled { p = p.stilled }
            let gaze = body.gaze.clamp(x: p.gazeX, y: p.gazeY)
            let height = eyeHeight * max(0, min(1, p.lid))
            times.append(into)
            lean.append(p.lean)
            scaleX.append(1 - (p.breath - 1) * 0.5)
            scaleY.append(p.breath)
            eyesX.append(body.eyes.x + gaze.x)
            eyesY.append(body.eyes.y + gaze.y)
            lid.append(max(0, min(1, p.lid)))
            open.append(height < 0.35 ? 0 : 1)
            catchlight.append(pointSize >= 24 && height > 1.4 ? 1 : 0)
            dots[0].append(p.dots.0)
            dots[1].append(p.dots.1)
            dots[2].append(p.dots.2)
        }
        func line(_ values: [Double], tolerance: Double) -> Track {
            simplified(times: times, values: values, tolerance: tolerance, duration: duration)
        }
        return FaceLoop(
            duration: duration,
            lean: line(lean, tolerance: 0.03),
            scaleX: line(scaleX, tolerance: 0.0004),
            scaleY: line(scaleY, tolerance: 0.0004),
            eyesX: line(eyesX, tolerance: 0.02),
            eyesY: line(eyesY, tolerance: 0.02),
            lid: line(lid, tolerance: 0.01),
            open: steps(times: times, values: open, duration: duration),
            catchlight: steps(times: times, values: catchlight, duration: duration),
            dots: dots.map { line($0, tolerance: 0.01) },
            eyeHeight: eyeHeight
        )
    }

    static func smoothstep(_ x: Double) -> Double {
        let x = max(0, min(1, x))
        return x * x * (3 - 2 * x)
    }

    /// The fewest keys that stay within `tolerance` of every sample, joined by straight lines
    /// (Ramer–Douglas–Peucker on time and value).
    static func simplified(times: [Double], values: [Double], tolerance: Double, duration: Double) -> Track {
        guard values.count > 2 else {
            return Track(keyTimes: times.map { $0 / duration }, values: values)
        }
        var keep = [Bool](repeating: false, count: values.count)
        keep[0] = true
        keep[values.count - 1] = true
        var spans = [(0, values.count - 1)]
        while let (first, last) = spans.popLast() {
            guard last - first > 1 else { continue }
            let t0 = times[first], v0 = values[first], t1 = times[last], v1 = values[last]
            var worst = 0.0, worstIndex = first
            for index in (first + 1)..<last {
                let expected = v0 + (v1 - v0) * (times[index] - t0) / (t1 - t0)
                let error = abs(values[index] - expected)
                if error > worst {
                    worst = error
                    worstIndex = index
                }
            }
            guard worst > tolerance else { continue }
            keep[worstIndex] = true
            spans.append((first, worstIndex))
            spans.append((worstIndex, last))
        }
        var track = Track(keyTimes: [], values: [])
        for index in values.indices where keep[index] {
            track.keyTimes.append(times[index] / duration)
            track.values.append(values[index])
        }
        return track
    }

    /// A discrete track: each value from the sample where it begins to the next change.
    static func steps(times: [Double], values: [Double], duration: Double) -> Track {
        var track = Track(keyTimes: [0], values: [])
        for (index, value) in values.enumerated() where index == 0 || value != values[index - 1] {
            if index > 0 { track.keyTimes.append(times[index] / duration) }
            track.values.append(value)
        }
        track.keyTimes.append(1)
        return track
    }

    /// The value `track` holds `at` seconds into the loop: linear between keys, or the step a
    /// discrete track is on. Tests and the hand-off from a drawn face use it.
    public func value(of track: Track, at seconds: Double) -> Double {
        let x = max(0, min(1, seconds / duration))
        if track.keyTimes.count == track.values.count + 1 {
            let step = track.keyTimes.lastIndex { $0 <= x } ?? 0
            return track.values[min(step, track.values.count - 1)]
        }
        guard let next = track.keyTimes.firstIndex(where: { $0 >= x }) else { return track.values.last ?? 0 }
        guard next > 0 else { return track.values[0] }
        let a = track.keyTimes[next - 1], b = track.keyTimes[next]
        let p = b > a ? (x - a) / (b - a) : 1
        return track.values[next - 1] + (track.values[next] - track.values[next - 1]) * p
    }
}
