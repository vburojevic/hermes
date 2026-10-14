import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code's module grid (`true` = dark), made by CoreImage at error-correction level H
/// so the Hermes mark can sit in the middle without costing scans.
nonisolated struct QRMatrix: Equatable, Sendable {
    let size: Int
    private let modules: [Bool]
    /// CIContexts are expensive and thread-safe: make one.
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    init?(_ text: String) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"
        guard let image = filter.outputImage else { return nil }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, width == height else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height)
        Self.context.render(image, toBitmap: &pixels, rowBytes: width, bounds: extent, format: .L8, colorSpace: nil)
        // CoreImage adds a quiet zone; keep only the code, read by its dark extent.
        let dark = pixels.map { $0 < 128 }
        let rows = (0..<height).filter { y in (0..<width).contains { dark[y * width + $0] } }
        let columns = (0..<width).filter { x in (0..<height).contains { dark[$0 * width + x] } }
        guard let top = rows.first, let bottom = rows.last, let left = columns.first, let right = columns.last,
              bottom - top == right - left
        else { return nil }
        size = bottom - top + 1
        var grid: [Bool] = []
        grid.reserveCapacity(size * size)
        for y in top...bottom {
            for x in left...right { grid.append(dark[y * width + x]) }
        }
        modules = grid
    }

    subscript(x: Int, y: Int) -> Bool { modules[y * size + x] }

    /// One of the three 7×7 finder patterns in the corners.
    func isFinder(x: Int, y: Int) -> Bool {
        (x < 7 && y < 7) || (x >= size - 7 && y < 7) || (x < 7 && y >= size - 7)
    }
}

/// A pairing QR code: soft round modules, rounded finder eyes, and the Hermes wing in the middle.
/// Always dark on white, whatever the theme, so every camera reads it.
struct PairingCodeView: View {
    let matrix: QRMatrix

    /// Modules of white around the code (the QR quiet zone).
    private let quietZone: CGFloat = 3.5

    var body: some View {
        Canvas { context, canvas in
            let side = min(canvas.width, canvas.height)
            let cell = side / (CGFloat(matrix.size) + quietZone * 2)
            let origin = CGPoint(x: (canvas.width - side) / 2 + quietZone * cell, y: (canvas.height - side) / 2 + quietZone * cell)
            let ink = GraphicsContext.Shading.color(.black)
            let hole = logoCells

            for y in 0..<matrix.size {
                for x in 0..<matrix.size where matrix[x, y] && !matrix.isFinder(x: x, y: y) && !hole.contains(x: x, y: y) {
                    let rect = CGRect(x: origin.x + CGFloat(x) * cell, y: origin.y + CGFloat(y) * cell, width: cell, height: cell)
                        .insetBy(dx: cell * 0.06, dy: cell * 0.06)
                    context.fill(Path(roundedRect: rect, cornerRadius: rect.width * 0.38, style: .continuous), with: ink)
                }
            }
            for (x, y) in [(0, 0), (matrix.size - 7, 0), (0, matrix.size - 7)] {
                let outer = CGRect(x: origin.x + CGFloat(x) * cell, y: origin.y + CGFloat(y) * cell, width: cell * 7, height: cell * 7)
                var ring = Path(roundedRect: outer, cornerRadius: cell * 2.1, style: .continuous)
                ring.addPath(Path(roundedRect: outer.insetBy(dx: cell, dy: cell), cornerRadius: cell * 1.35, style: .continuous))
                context.fill(ring, with: ink, style: FillStyle(eoFill: true))
                context.fill(Path(roundedRect: outer.insetBy(dx: cell * 2, dy: cell * 2), cornerRadius: cell * 0.95, style: .continuous), with: ink)
            }
        }
        .background(.white)
        .overlay {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                let cell = side / (CGFloat(matrix.size) + quietZone * 2)
                LogoBadge()
                    .frame(width: CGFloat(logoCells.width) * cell * 0.84)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Pairing code")
    }

    /// The centre square kept clear for the mark: about a fifth of the code, never more than
    /// level H can recover.
    private var logoCells: CellSquare {
        var width = Int((Double(matrix.size) * 0.22).rounded())
        if width % 2 != matrix.size % 2 { width += 1 }
        let start = (matrix.size - width) / 2
        return CellSquare(start: start, width: width)
    }

    private struct CellSquare {
        let start: Int
        let width: Int
        func contains(x: Int, y: Int) -> Bool {
            (start..<start + width).contains(x) && (start..<start + width).contains(y)
        }
    }

    /// The app icon in miniature: a white wing on near-black.
    private struct LogoBadge: View {
        var body: some View {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)
                    .fill(Color(white: 0.06))
                    .overlay { HermesMark().fill(.white).padding(side * 0.2) }
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }
}

#Preview {
    if let matrix = QRMatrix("hermesapp://connect?v=1&name=MacBook%20Pro&gateway=https%3A%2F%2Fmac.tail0.ts.net%3A8642&key=0123456789abcdef0123456789abcdef0123456789abcdef") {
        PairingCodeView(matrix: matrix)
            .frame(width: 280)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(40)
            .background(Color.black)
    }
}
