import SwiftUI

/// The Hermes wing as a SwiftUI shape.
nonisolated struct HermesMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path(HermesMarkPath.path(in: rect))
    }
}

/// The mark with an optional light sweep, used while Hermes is working.
struct HermesMarkView: View {
    var isAnimating = false
    var color: Color = Theme.primaryText

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pausesDecorativeMotion) private var motionPaused

    var body: some View {
        HermesMark()
            .fill(color)
            .overlay {
                if isAnimating && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: motionPaused)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: phase - 0.25),
                                .init(color: Theme.canvas.opacity(0.75), location: phase),
                                .init(color: .clear, location: phase + 0.25),
                            ],
                            startPoint: .bottomLeading,
                            endPoint: .topTrailing
                        )
                        .mask(HermesMark())
                    }
                }
            }
            .opacity(isAnimating && reduceMotion ? 0.6 : 1)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: 32) {
        HermesMarkView().frame(width: 96)
        HermesMarkView(isAnimating: true).frame(width: 32)
    }
    .padding()
}
