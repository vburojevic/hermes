#if os(iOS)
import AVFoundation
import HermesKit
import SwiftUI
import VisionKit

/// Scans a pairing QR code with the camera (VisionKit's live data scanner), then connects in
/// the same sheet: the camera gives way to the connect step without the sheet closing.
struct PairingScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var found: PairingLink?
    /// Set a beat after `found`, once the brackets have closed on the code.
    @State private var connecting: PairingLink?
    @State private var problem: ScanProblem?
    @State private var problems = 0

    private enum ScanProblem: Equatable {
        case notHermes, newerVersion

        var message: LocalizedStringKey {
            switch self {
            case .notHermes: "That isn't a Hermes pairing code."
            case .newerVersion: "This code needs a newer Hermes. Update the app, then scan again."
            }
        }
    }

    var body: some View {
        ZStack {
            if let connecting {
                PairingConnectView(link: connecting, connectsRightAway: true)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            } else {
                NavigationStack {
                    content
                        .navigationTitle("Scan Pairing Code")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { dismiss() }
                            }
                        }
                }
                .transition(.opacity)
            }
        }
        .sensoryFeedback(.success, trigger: found != nil)
        .sensoryFeedback(.warning, trigger: problems)
        .task {
            // Only ask for the camera where VisionKit can actually scan.
            if DataScannerViewController.isSupported, access == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                access = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
        .task(id: problems) {
            // A wrong code's message fades after a moment, so the next try starts clean.
            guard problem != nil else { return }
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { problem = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !DataScannerViewController.isSupported {
            #if DEBUG
            if UserDefaults.standard.string(forKey: "HERMES_SIMULATE_SCAN") != nil {
                simulatedScanner
            } else {
                unsupported
            }
            #else
            unsupported
            #endif
        } else {
            switch access {
            case .authorized:
                ZStack {
                    PairingScanner(isFinished: found != nil) { payload in
                        handle(payload)
                    }
                    .ignoresSafeArea()
                    overlay
                }
            case .notDetermined:
                Spinner(size: .regular)
            default:
                VStack(spacing: 16) {
                    unavailable(
                        "Camera access is off",
                        detail: "Allow Hermes to use the camera in Settings, or scan the code with the Camera app."
                    )
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .prominentGlassButton()
                }
            }
        }
    }

    private var unsupported: some View {
        unavailable(
            "This device can't scan codes",
            detail: "Open the Camera app and point it at the code instead; Hermes opens from there."
        )
    }

    #if DEBUG
    /// `-HERMES_SIMULATE_SCAN <url>`: the viewfinder over a stand-in, reading that link after a
    /// moment (simulators have no scanner).
    private var simulatedScanner: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            overlay
        }
        .task {
            try? await Task.sleep(for: .seconds(2.2))
            if let payload = UserDefaults.standard.string(forKey: "HERMES_SIMULATE_SCAN") { handle(payload) }
        }
    }
    #endif

    private var overlay: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)
            Viewfinder(isFound: found != nil)
                .frame(maxWidth: 260, maxHeight: 260)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 40)
            Spacer(minLength: 12)
            Group {
                if let problem {
                    Text(problem.message)
                } else if found != nil {
                    Text("Got it")
                } else {
                    Text("On your Mac, open the gateway menu and choose Pair a Device.")
                }
            }
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
            // Always light-on-dark: the camera behind it can be anything, often a bright screen.
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
            .layoutPriority(1)
            .contentTransition(.opacity)
            .animation(.snappy, value: problem)
            .animation(.snappy, value: found != nil)
        }
    }

    private func handle(_ payload: String) {
        guard found == nil else { return }
        guard let url = URL(string: payload) else { return flag(.notHermes) }
        if let link = PairingLink(url: url) {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.72)) {
                found = link
                problem = nil
            }
            AccessibilityNotification.Announcement(String(localized: "Pairing code found")).post()
            Task {
                // Let the brackets close on the code before handing over.
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 250 : 650))
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.45)) { connecting = link }
            }
        } else if let scheme = url.scheme?.lowercased(), PairingLink.acceptedSchemes.contains(scheme) {
            flag(.newerVersion)
        } else {
            flag(.notHermes)
        }
    }

    private func flag(_ new: ScanProblem) {
        withAnimation(.snappy) { problem = new }
        problems += 1
        AccessibilityNotification.Announcement(new == .notHermes
            ? String(localized: "That isn't a Hermes pairing code.")
            : String(localized: "This code needs a newer Hermes.")).post()
    }

    private func unavailable(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "qrcode.viewfinder")
        } description: {
            Text(detail)
        }
    }
}

/// The scanner's frame: four corner brackets that breathe while looking, with a soft sweep, then
/// close in and turn into a check once a pairing code is read.
private struct Viewfinder: View {
    let isFound: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pausesDecorativeMotion) private var motionPaused

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let breathes = !(isFound || reduceMotion || motionPaused)
            ZStack {
                // One view throughout (no branch), so closing in on a code is a single motion.
                CornerBrackets()
                    .stroke(isFound ? Theme.success : .white, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .shadow(color: .black.opacity(0.35), radius: 6)
                    .phaseAnimator([1.0, 1.035]) { content, scale in
                        content.scaleEffect(breathes ? scale : 1)
                    } animation: { _ in .easeInOut(duration: 1.4) }
                    .scaleEffect(isFound ? 0.78 : 1)
                if isFound {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: side * 0.24, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.success)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                } else if !reduceMotion {
                    SweepLine(paused: motionPaused)
                        .padding(side * 0.1)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

/// Four rounded L-shaped corners.
nonisolated private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let length = rect.width * 0.2
        let radius = rect.width * 0.09
        var path = Path()
        for (corner, dx, dy) in [
            (CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
            (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0),
        ] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * radius))
            path.addQuadCurve(to: CGPoint(x: corner.x + dx * radius, y: corner.y), control: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
        }
        return path
    }
}

/// A soft line gliding down and up inside the frame while the scanner looks.
private struct SweepLine: View {
    let paused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6
            let position = 0.5 - 0.5 * cos(t * 2 * .pi) // eases at both ends
            GeometryReader { proxy in
                LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 2)
                    .shadow(color: .white.opacity(0.6), radius: 6)
                    .offset(y: proxy.size.height * position)
            }
        }
        .allowsHitTesting(false)
    }
}

/// VisionKit's scanner, set up for QR codes only.
private struct PairingScanner: UIViewControllerRepresentable {
    /// Once a code is accepted the camera stays off, even while the sheet animates away.
    let isFinished: Bool
    let onPayload: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onPayload = onPayload
        if isFinished {
            if scanner.isScanning { scanner.stopScanning() }
        } else if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onPayload: (String) -> Void
        /// Payloads already judged, so a wrong code held in view isn't reported every frame.
        private var seen: Set<String> = []

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode(let barcode) = item, let payload = barcode.payloadStringValue,
                      seen.insert(payload).inserted
                else { continue }
                onPayload(payload)
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            // A code that left the frame can be judged again when it comes back.
            for item in removedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue { seen.remove(payload) }
            }
        }
    }
}
#endif
