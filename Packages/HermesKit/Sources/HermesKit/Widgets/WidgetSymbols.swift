import Foundation

/// The SF Symbols a payload may name (`icon`, `symbol` fields; contract §7): the names the design
/// project draws (`controls/symbols.elyx`) and the contract's core set, plus their `.fill` and
/// `.circle` forms. Anything else draws the primitive's default glyph, without an error.
public enum WidgetSymbols {
    static let names: Set<String> = [
        "15.arrow.trianglehead.clockwise", "15.arrow.trianglehead.counterclockwise", "airplane",
        "airplane.departure", "airpods", "airpods.pro", "alarm", "allergens",
        "antenna.radiowaves.left.and.right", "app.badge.fill", "applelogo", "archivebox",
        "arrow.clockwise", "arrow.down", "arrow.down.circle", "arrow.down.circle.fill",
        "arrow.down.right", "arrow.down.to.line", "arrow.forward.to.line",
        "arrow.triangle.2.circlepath", "arrow.triangle.branch", "arrow.turn.up.right", "arrow.up",
        "arrow.up.arrow.down", "arrow.up.circle.fill", "arrow.up.forward.app",
        "arrow.up.forward.square", "arrow.up.right", "arrow.uturn.backward", "arrow.uturn.left",
        "arrowshape.turn.up.left", "arrowtriangle.down.fill", "arrowtriangle.up.fill", "at",
        "bag.fill", "banknote.fill", "battery.100percent", "bed.double.fill", "bell", "bell.slash",
        "bicycle", "bold", "bolt.circle.fill", "bolt.fill", "bolt.horizontal.circle", "bolt.slash",
        "book.closed", "book.fill", "brain", "bubble.left", "bubble.left.and.bubble.right",
        "bubble.left.and.text.bubble.right", "bubble.left.fill", "building.2.fill", "bus",
        "bus.fill", "calendar", "calendar.badge.clock", "calendar.circle.fill", "camera",
        "camera.fill", "camera.viewfinder", "captions.bubble", "captions.bubble.fill", "car.fill",
        "carrot.fill", "cart.fill", "cellularbars", "character.cursor.ibeam", "chart.bar",
        "chart.bar.fill", "chart.bar.xaxis", "chart.line.uptrend.xyaxis", "chart.pie.fill",
        "checklist", "checklist.checked", "checkmark", "checkmark.circle", "checkmark.circle.fill",
        "checkmark.seal.fill", "checkmark.shield.fill", "checkmark.square", "chevron.down",
        "chevron.left", "chevron.left.forwardslash.chevron.right", "chevron.right", "chevron.up",
        "chevron.up.chevron.down", "circle", "circle.fill", "circle.lefthalf.filled", "clock",
        "clock.arrow.circlepath", "clock.badge.exclamationmark", "clock.fill",
        "cloud.bolt.rain.fill", "cloud.fill", "cloud.fog.fill", "cloud.rain.fill",
        "cloud.snow.fill", "cloud.sun.fill", "command", "cpu", "creditcard.fill", "cross.case.fill",
        "curlybraces", "delete.left", "desktopcomputer", "doc.fill", "doc.on.clipboard",
        "doc.on.doc", "doc.text", "drop.fill", "ear", "ellipsis", "ellipsis.bubble",
        "ellipsis.circle", "envelope", "envelope.fill", "equal", "exclamationmark.circle",
        "exclamationmark.circle.fill", "exclamationmark.shield", "exclamationmark.triangle",
        "exclamationmark.triangle.fill", "externaldrive", "externaldrive.fill", "eye", "eye.slash",
        "face.smiling", "figure.run", "figure.walk", "film.fill", "flame.fill",
        "flashlight.off.fill", "folder", "folder.fill", "fork.knife", "gamecontroller",
        "gauge.with.dots.needle.33percent", "gauge.with.dots.needle.67percent", "gauge.with.needle",
        "gearshape", "gearshape.fill", "gift.fill", "globe", "globe.badge.chevron.backward",
        "graduationcap.fill", "hammer", "hand.raised", "hand.raised.fill", "hand.thumbsdown.fill",
        "hand.thumbsup.fill", "hand.wave", "headphones", "heart.fill", "hourglass",
        "hourglass.bottomhalf.filled", "house.fill", "info.circle", "info.circle.fill", "ipad",
        "iphone", "key.fill", "key.horizontal", "keyboard", "keyboard.chevron.compact.down",
        "ladybug.fill", "laptopcomputer", "leaf.fill", "lightbulb", "lightbulb.fill",
        "line.3.horizontal", "link", "list.bullet", "list.bullet.circle", "list.bullet.rectangle",
        "location.fill", "lock.fill", "lock.open", "lock.shield", "lock.shield.fill", "macwindow",
        "magnifyingglass", "map.fill", "mappin.and.ellipse", "medal.fill", "memorychip",
        "menubar.rectangle", "message", "message.fill", "mic", "microphone.fill",
        "microphone.slash.fill", "minus", "moon", "moon.stars.fill", "moon.zzz", "network",
        "network.slash", "newspaper.fill", "number", "number.circle", "number.square", "paperclip",
        "paperplane", "pause.fill", "pencil", "pencil.line", "person.2", "person.2.circle",
        "person.2.fill", "person.3", "person.badge.key", "person.badge.key.fill",
        "person.badge.plus", "person.crop.circle", "person.crop.circle.badge.questionmark",
        "person.crop.circle.fill", "person.fill", "person.wave.2", "phone.bubble",
        "phone.down.fill", "phone.fill", "photo", "photo.badge.plus", "photo.on.rectangle",
        "pills.fill", "pin", "pin.fill", "pin.slash", "play.fill", "plus", "plus.circle.fill",
        "power", "powerplug.fill", "puzzlepiece.extension", "qrcode", "qrcode.viewfinder",
        "questionmark.bubble", "questionmark.circle", "questionmark.circle.fill", "quote.opening",
        "record.circle", "rectangle.and.pencil.and.ellipsis", "rectangle.compress.vertical",
        "rectangle.on.rectangle", "rectangle.portrait.and.arrow.right", "rectangle.stack",
        "rectangle.stack.fill", "repeat", "return", "safari", "server.rack",
        "shield.lefthalf.filled", "shift", "shippingbox", "shippingbox.fill", "sidebar.leading",
        "sidebar.left", "sidebar.right", "slash.circle", "slider.horizontal.3", "sofa.fill",
        "sparkle", "sparkles", "speaker.slash.fill", "speaker.wave.2", "speaker.wave.3.fill",
        "sportscourt.fill", "square", "square.and.arrow.down", "square.and.arrow.down.on.square",
        "square.and.arrow.up", "square.and.pencil", "square.and.pencil.circle", "square.grid.2x2",
        "square.on.square", "square.stack.3d.up.fill", "star", "star.fill",
        "star.leadinghalf.filled", "stop.circle", "stop.fill", "storefront.fill", "suitcase.fill",
        "sun.horizon.fill", "sun.max", "sun.max.fill", "sunrise.fill", "sunset.fill", "switch.2",
        "tag", "takeoutbag.and.cup.and.straw.fill", "target", "terminal", "text.alignleft",
        "text.badge.plus", "text.bubble", "text.quote", "thermometer.medium", "ticket.fill",
        "timer", "tram.fill", "trash", "trash.fill", "tray", "tray.full.fill", "trophy",
        "trophy.fill", "truck.box.fill", "umbrella.fill", "video.fill", "wand.and.stars",
        "waveform", "waveform.circle.fill", "waveform.path.ecg", "wifi", "wifi.slash", "wind",
        "window.vertical.closed", "wrench.and.screwdriver", "xmark", "xmark.circle",
        "xmark.circle.fill", "xmark.octagon.fill", "xmark.shield",
    ]

    /// The symbol to draw for `name`, or `nil` for the primitive's default (unknown, private, or a
    /// `bot:` face, which the caller draws itself).
    public static func resolve(_ name: String?) -> String? {
        guard let name, !name.hasPrefix("bot:") else { return nil }
        if names.contains(name) { return name }
        for suffix in [".circle.fill", ".fill", ".circle"] where name.hasSuffix(suffix) {
            if names.contains(String(name.dropLast(suffix.count))) { return name }
        }
        return nil
    }

    /// The handle of a `bot:<handle>` icon.
    public static func botHandle(_ name: String?) -> String? {
        guard let name, name.hasPrefix("bot:") else { return nil }
        let handle = String(name.dropFirst(4))
        return handle.isEmpty ? nil : handle
    }
}
