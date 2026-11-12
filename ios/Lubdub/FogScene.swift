import SwiftUI
import CoreImage
import UIKit

// The scene: one picture, shown two ways.
//
// Everything on the wall — the window behind the cards, the fog on a card,
// the clear face a wipe uncovers — is the same picture in the same key.
// The fog is that picture blurred, plus a breath of white, grain, and a few
// condensed droplets; wiping reveals the sharp version underneath. The rule
// that holds the page together: fog is never a color laid on top, it is the
// scene itself gone soft.
//
// Ships with a built-in evening-window scene. Both the page and the cards
// can instead use a photo of your own (kept locally in Documents, never
// uploaded anywhere), with an optional darkening/whitening veil per layer
// and a switch for whether the window itself fogs up.

/// Which letters have been wiped clear. Local only — on a new device you
/// wipe them again, which is not a bug.
@MainActor
final class WipedLetters: ObservableObject {
    static let shared = WipedLetters()
    private let key = "lubdub_wiped"
    @Published private(set) var ids: Set<String>

    private init() { ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    func mark(_ id: String) {
        guard !ids.contains(id) else { return }
        ids.insert(id)
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
}

/// Deterministic randomness from an id: the same letter grows the same
/// droplets and the same fog mottle every time.
struct FogSeed: RandomNumberGenerator {
    private var s: UInt64
    init(_ str: String) {
        var h: UInt64 = 1469598103934665603
        for b in str.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        s = h | 1
    }
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@MainActor
final class FogScene: ObservableObject {
    static let shared = FogScene()

    struct Pair {
        var sharp: UIImage?
        var fog: UIImage?
        /// A dark scene carries light ink, a light one dark ink. The text
        /// follows the scene; it never sits on its own backing color.
        var dark = true
        var ink: Color { dark ? Color(white: 0.97) : Color(red: 0.15, green: 0.17, blue: 0.21) }
        var soft: Color { ink.opacity(0.62) }
    }

    @Published private(set) var page = Pair()
    @Published private(set) var card = Pair()

    // Looks, all local (UserDefaults):
    @Published var bgVeil: Double { didSet { UserDefaults.standard.set(bgVeil, forKey: "lubdub_bg_veil") } }
    @Published var cardVeil: Double { didSet { UserDefaults.standard.set(cardVeil, forKey: "lubdub_card_veil") } }
    @Published var bgFog: Bool { didSet { UserDefaults.standard.set(bgFog, forKey: "lubdub_bg_fog") } }

    private var pageKey = "", cardKey = ""
    private static let ci = CIContext(options: [.cacheIntermediates: false])

    private init() {
        let d = UserDefaults.standard
        bgVeil = d.double(forKey: "lubdub_bg_veil")
        cardVeil = d.double(forKey: "lubdub_card_veil")
        bgFog = d.object(forKey: "lubdub_bg_fog") == nil ? true : d.bool(forKey: "lubdub_bg_fog")
        refresh()
    }

    func pair(card isCard: Bool) -> Pair { isCard ? card : page }

    // MARK: - Your own photo (stored locally, never uploaded)

    static func sceneFile(card: Bool) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(card ? "lubdub-scene-card.jpg" : "lubdub-scene-bg.jpg")
    }

    func hasCustom(card: Bool) -> Bool {
        FileManager.default.fileExists(atPath: Self.sceneFile(card: card).path)
    }

    func setCustom(_ data: Data, card: Bool) {
        guard let photo = UIImage(data: data) else { return }
        let k = min(1, 1600 / max(photo.size.width, photo.size.height))
        let size = CGSize(width: max(1, photo.size.width * k), height: max(1, photo.size.height * k))
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
        let flat = UIGraphicsImageRenderer(size: size, format: f).image { _ in
            photo.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = flat.jpegData(compressionQuality: 0.85) else { return }
        try? jpeg.write(to: Self.sceneFile(card: card), options: .atomic)
        if card { cardKey = "" } else { pageKey = "" }
        refresh()
    }

    func clearCustom(card: Bool) {
        try? FileManager.default.removeItem(at: Self.sceneFile(card: card))
        if card { cardKey = "" } else { pageKey = "" }
        refresh()
    }

    // MARK: - Building the pairs

    func refresh() {
        var changed = false
        if hasCustom(card: false) {
            if let p = load(Self.sceneFile(card: false), key: &pageKey) { page = p; changed = true }
        } else if pageKey != "default" {
            pageKey = "default"
            page = Self.defaultPair
            changed = true
        }
        if hasCustom(card: true) {
            if let p = load(Self.sceneFile(card: true), key: &cardKey) { card = p }
        } else if cardKey != "page" || changed {
            cardKey = "page"
            card = page   // the cards share the window's scene by default
        }
    }

    private func load(_ url: URL, key: inout String) -> Pair? {
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
            as? Date)?.timeIntervalSince1970 ?? 0
        let k = "\(url.lastPathComponent)@\(mtime)"
        guard k != key, let data = try? Data(contentsOf: url), let photo = UIImage(data: data) else { return nil }
        key = k
        return Self.pair(from: photo)
    }

    static func pair(from flat: UIImage) -> Pair {
        guard let sharp = flat.cgImage else { return Pair() }
        let src = CIImage(cgImage: sharp)
        let blurred = src.clampedToExtent().applyingGaussianBlur(sigma: 26).cropped(to: src.extent)
        guard let fog = ci.createCGImage(blurred, from: src.extent) else {
            return Pair(sharp: flat, fog: flat, dark: luminance(sharp) < 0.56)
        }
        return Pair(sharp: UIImage(cgImage: sharp), fog: UIImage(cgImage: fog),
                    dark: luminance(fog) < 0.56)
    }

    /// The built-in scene: an evening window — a dusk gradient and a few
    /// far-away lights, so wiping the fog visibly uncovers something.
    static let defaultPair: Pair = {
        let size = CGSize(width: 900, height: 1350)
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: f).image { ctx in
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [UIColor(red: 0.33, green: 0.40, blue: 0.47, alpha: 1).cgColor,
                                        UIColor(red: 0.12, green: 0.15, blue: 0.21, alpha: 1).cgColor] as CFArray,
                               locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            var rng = FogSeed("default-scene")
            for _ in 0..<16 {
                let x = CGFloat.random(in: 0...size.width, using: &rng)
                let y = CGFloat.random(in: (size.height * 0.3)...size.height, using: &rng)
                let r = CGFloat.random(in: 5...24, using: &rng)
                let warm = Double.random(in: 0...1, using: &rng) < 0.72
                let base = warm ? UIColor(red: 0.95, green: 0.78, blue: 0.50, alpha: 1)
                                : UIColor(red: 0.68, green: 0.80, blue: 0.95, alpha: 1)
                let halo: [(CGFloat, CGFloat)] = [(2.8, 0.08), (1.7, 0.2), (1.0, 0.6)]
                for (scale, alpha) in halo {
                    base.withAlphaComponent(alpha).setFill()
                    ctx.cgContext.fillEllipse(in: CGRect(x: x - r * scale, y: y - r * scale,
                                                         width: r * scale * 2, height: r * scale * 2))
                }
            }
        }
        return pair(from: img)
    }()

    private static func luminance(_ img: CGImage) -> Double {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0.3 }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.299 * Double(px[0]) + 0.587 * Double(px[1]) + 0.114 * Double(px[2])) / 255
    }

    // MARK: - Fog textures

    /// Uneven fog thickness: a tiny noise image scaled up until it smears
    /// into patches, fixed per letter id. Used on light scenes, where a white
    /// overlay would vanish — there the fog is made of brightness variation
    /// (multiply), not of whiteness.
    private static var mottles: [String: UIImage] = [:]
    static func mottle(_ seed: String) -> UIImage {
        if let m = mottles[seed] { return m }
        let n = 9
        var bytes = [UInt8](repeating: 0, count: n * n)
        var g = FogSeed(seed + "-mottle")
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 150...255, using: &g) }
        let cs = CGColorSpaceCreateDeviceGray()
        guard let p = CGDataProvider(data: Data(bytes) as CFData),
              let small = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
                                  space: cs, bitmapInfo: CGBitmapInfo(rawValue: 0), provider: p, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else { return UIImage() }
        let src = CIImage(cgImage: small).transformed(by: CGAffineTransform(scaleX: 20, y: 20))
        let blurred = src.clampedToExtent().applyingGaussianBlur(sigma: 14).cropped(to: src.extent)
        let img = ci.createCGImage(blurred, from: src.extent).map { UIImage(cgImage: $0) } ?? UIImage()
        mottles[seed] = img
        return img
    }

    /// Frosted-glass grain: a small noise tile, repeated.
    static let grain: UIImage = {
        let n = 96
        var bytes = [UInt8](repeating: 0, count: n * n)
        var g = FogSeed("grain")
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 70...185, using: &g) }
        let cs = CGColorSpaceCreateDeviceGray()
        guard let p = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
                               space: cs, bitmapInfo: CGBitmapInfo(rawValue: 0), provider: p, decode: nil,
                               shouldInterpolate: true, intent: .defaultIntent) else { return UIImage() }
        return UIImage(cgImage: cg, scale: 2, orientation: .up)
    }()
}

// MARK: - Layers

/// The scene filling whatever frame it's given. `blurred` picks the fogged
/// copy; `card` picks the cards' pair instead of the page's.
struct SceneLayer: View {
    var blurred: Bool
    var card = false
    @ObservedObject private var scene = FogScene.shared

    var body: some View {
        let pair = scene.pair(card: card)
        let veil = card ? scene.cardVeil : scene.bgVeil
        return Color.clear.overlay {
            if let img = blurred ? pair.fog : pair.sharp {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.48),
                                        Color(red: 0.17, green: 0.20, blue: 0.26)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        // The veil follows the scene's own key — a dark scene darkens, a
        // light one whitens — so the ink never has to flip against it.
        .overlay { if veil > 0 { (pair.dark ? Color.black : Color.white).opacity(veil * 0.85) } }
        .clipped()
    }
}

/// Droplets condensed on the fog: little lenses, dark above, bright below,
/// a sliver of highlight top-left.
struct FogDrops: View {
    let seed: String
    var count = 12

    var body: some View {
        Canvas { ctx, size in
            var rng = FogSeed(seed)
            for _ in 0..<count {
                let x = CGFloat.random(in: 10...max(11, size.width - 10), using: &rng)
                let y = CGFloat.random(in: 10...max(11, size.height - 10), using: &rng)
                let r = 1.4 + 3.6 * pow(CGFloat.random(in: 0...1, using: &rng), 2.4)
                let rect = CGRect(x: x - r, y: y - r * 1.08, width: r * 2, height: r * 2.16)
                ctx.fill(Path(ellipseIn: rect), with: .linearGradient(
                    Gradient(colors: [.black.opacity(0.22), .black.opacity(0.05), .white.opacity(0.5)]),
                    startPoint: CGPoint(x: x, y: rect.minY), endPoint: CGPoint(x: x, y: rect.maxY)))
                ctx.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.10)), lineWidth: 0.5)
                var glint = Path()
                glint.addArc(center: CGPoint(x: x, y: y), radius: r * 0.62,
                             startAngle: .degrees(200), endAngle: .degrees(250), clockwise: false)
                ctx.stroke(glint, with: .color(.white.opacity(0.75)),
                           style: .init(lineWidth: max(0.6, r * 0.2), lineCap: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The fog itself: the same scene blurred + a breath of white + grain
/// (+ droplets). Never a flat color on top.
struct FogSheet: View {
    let seed: String
    var drops = true
    var card = false
    @ObservedObject private var scene = FogScene.shared

    var body: some View {
        let light = !scene.pair(card: card).dark
        ZStack {
            SceneLayer(blurred: true, card: card)
            if light {
                // On a light scene the blur barely reads and white-on-white
                // disappears, so the fog becomes brightness relief instead:
                // multiplied grain, per-letter mottle patches, slightly
                // thicker toward the edges.
                Image(uiImage: FogScene.mottle(seed))
                    .resizable().interpolation(.high)
                    .blendMode(.multiply)
                    .opacity(0.18)
                Image(uiImage: FogScene.grain)
                    .resizable(resizingMode: .tile)
                    .blendMode(.multiply)
                    .opacity(0.12)
                RadialGradient(colors: [.clear, .black.opacity(0.06)],
                               center: .center, startRadius: 40, endRadius: 420)
                    .blendMode(.multiply)
                Color.white.opacity(0.06)
            } else {
                Color.white.opacity(0.18)
                Image(uiImage: FogScene.grain)
                    .resizable(resizingMode: .tile)
                    .blendMode(.overlay)
                    .opacity(0.42)
            }
            if drops { FogDrops(seed: seed) }
        }
        .compositingGroup()
    }
}

/// What a wipe uncovers: the same scene, sharp, pressed just enough for the
/// ink to stand on it.
struct ClearSheet: View {
    var card = false
    @ObservedObject private var scene = FogScene.shared

    var body: some View {
        ZStack {
            SceneLayer(blurred: false, card: card)
            (scene.pair(card: card).dark ? Color.black : Color.white).opacity(0.16)
        }
    }
}

/// Glass edge: clipped corners, a bright rim that catches light top-left,
/// a soft drop shadow.
struct GlassRim: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.14), .white.opacity(0.34)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
    }
}

/// The letters' type: a quiet serif. (The household build uses a handwriting
/// face here; ship your own if you have one licensed.)
enum LetterFont {
    static func hand(_ size: CGFloat) -> Font { .system(size: size, design: .serif) }
    static func small(_ size: CGFloat) -> Font { .system(size: size, design: .serif) }
}
