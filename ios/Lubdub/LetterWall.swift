import SwiftUI
import PhotosUI
import UIKit

// The wall: a fogged-up window with the letters as panes of misted glass.
//
// The page has no header. You arrive to a closed pile of cards; tapping (or
// dragging) fans them out along an arc that you spin up and down with
// inertia. Tapping the centered card pulls it out full-size, where a
// developed letter is wiped clear with a finger (WipeOverlay.swift); a
// locked one lets you thin the fog for a moment, then closes back over.
// Long-press a card to retract (locked) or remove (revealed) it.

struct LetterWall: View {
    @ObservedObject private var store = LetterStore.shared
    @ObservedObject private var scene = FogScene.shared

    @StateObject private var spin = WheelSpin()
    @State private var dragFrom: (pos: CGFloat, dy: CGFloat)?
    @State private var askDelete: Letter?
    @State private var wipe: Letter?
    @State private var composeOpen = false

    static let cardSize = CGSize(width: 268, height: 184)
    /// The arc: its center sits off-screen to the left, the cards hang on
    /// the right edge of a big wheel. 19° between neighbors is about one
    /// card of travel.
    private let radius: CGFloat = 600
    private let step: CGFloat = 19 * .pi / 180
    private var pitch: CGFloat { radius * sin(step) }

    var body: some View {
        let letters = store.letters
        GeometryReader { geo in
            let s = geo.size
            ZStack {
                // The whole window fogs up — same stuff as the cards' fog.
                // Switchable: off means the scene stays sharp and only the
                // cards carry fog.
                Color.clear.overlay {
                    if scene.bgFog { FogSheet(seed: "window", drops: false) } else { SceneLayer(blurred: false) }
                }
                .ignoresSafeArea()
                // Once fanned out, tapping the empty window closes the pile.
                .contentShape(Rectangle())
                .onTapGesture {
                    guard spin.open else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    spin.setOpen(false)
                }

                if letters.isEmpty {
                    Text(store.error ?? (store.loaded
                        ? "No letters yet.\nWrite one, lock it — it develops when you chose."
                        : ""))
                        .font(LetterFont.hand(15)).lineSpacing(6)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(scene.page.soft)
                        .padding(.horizontal, 40)
                } else {
                    wheel(letters, in: s)
                }
            }
            .frame(width: s.width, height: s.height)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(spinGesture(count: letters.count))
        .overlay(alignment: .bottomTrailing) { composeButton }
        .overlay {
            if let l = wipe {
                WipeOverlay(letter: l) { wipe = nil }
            }
        }
        .sheet(isPresented: $composeOpen) { Composer() }
        .task {
            // No websocket on the open-source server: poll while visible.
            await store.reload()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                await store.reload()
            }
        }
        .confirmationDialog(askDelete?.locked == true ? "Take it back?" : "Remove this letter?",
                            isPresented: .init(get: { askDelete != nil }, set: { if !$0 { askDelete = nil } }),
                            titleVisibility: .visible, presenting: askDelete) { l in
            Button(l.locked ? "Retract" : "Remove", role: .destructive) {
                Task { _ = await store.delete(l.id) }
            }
        } message: { l in
            Text(l.locked
                ? "The agent will be told something was taken back — never what."
                : "It only leaves the wall. What's been read can't be unread.")
        }
    }

    /// Pile <-> arc. Closed = the arc's spread collapses to 0 (every card on
    /// the center slot), each tilted a touch and nudged up to show an edge;
    /// open = the spread returns to 19°. Every in-between frame interpolates
    /// on `fan`, so the cards deal out of the pile along the arc.
    private func wheel(_ letters: [Letter], in s: CGSize) -> some View {
        let fan = spin.fan
        let pile = max(0, 1 - fan)
        let mid = CGPoint(x: s.width * (0.47 + 0.03 * pile), y: s.height * 0.47)
        let cx = mid.x - radius
        let pos = spin.pos
        let top = Int(pos.rounded())
        return ZStack {
            ForEach(Array(letters.enumerated()), id: \.element.id) { i, l in
                let d = CGFloat(i) - pos
                if abs(d) < 3.4 {
                    let th = d * step * fan
                    let front = abs(d) < 0.5
                    let a = abs(d)
                    // The centered card grows a little (smoothstep), and
                    // shrinks back as you spin past it.
                    let f = max(0, 1 - a)
                    let lift = 0.08 * f * f * (3 - 2 * f)
                    let arcScale = 1 - min(a, 2.5) * 0.05 + lift
                    let pileScale = 1 - min(a, 3) * 0.045
                    let tilt = i == top ? 0 : Self.tilt(l.id)
                    LetterFogCard(letter: l)
                        .scaleEffect(pileScale * pile + arcScale * min(fan, 1.2))
                        .rotationEffect(.radians(th) + .degrees(tilt * pile))
                        .position(x: cx + radius * cos(th),
                                  y: mid.y + radius * sin(th) - min(a, 3) * 11 * pile)
                        .zIndex(Double(10 - a))
                        .onTapGesture {
                            if !spin.open {
                                // Closed: any tap fans the pile out first.
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                spin.setOpen(true)
                            } else if front {
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                wipe = l
                            } else {
                                spin.glide(to: CGFloat(i))
                            }
                        }
                        .onLongPressGesture(minimumDuration: 0.55) {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            askDelete = l
                        }
                }
            }
        }
        .frame(width: s.width, height: s.height)
    }

    /// How much each card leans while piled: -8°…8°, fixed per id.
    private static func tilt(_ id: String) -> Double {
        var g = FogSeed(id + "-tilt")
        return Double.random(in: -8...8, using: &g)
    }

    /// Vertical drag = spin the wheel; release keeps the finger's velocity
    /// and settles on the nearest card.
    ///
    /// Don't animate `pos` with SwiftUI (withAnimation): SwiftUI would
    /// interpolate each card's *computed screen position* — chords instead
    /// of arcs, cards entering from off-screen popping straight to their
    /// destination, and the release velocity zeroed. WheelSpin drives `pos`
    /// frame by frame instead, and a touch mid-glide stops it right there.
    private func spinGesture(count: Int) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                // Measure from where the finger actually started moving —
                // don't replay the first 6pt in one jump.
                if dragFrom == nil {
                    spin.stop()
                    dragFrom = (spin.pos, v.translation.height)
                    spin.setOpen(true)   // dragging a closed pile also fans it out
                }
                guard let from = dragFrom else { return }
                let top = CGFloat(max(0, count - 1))
                var p = from.pos - (v.translation.height - from.dy) / pitch
                // Past the ends you can still pull a little, damped.
                if p < 0 { p = p * 0.35 } else if p > top { p = top + (p - top) * 0.35 }
                spin.set(p)
            }
            .onEnded { v in
                guard dragFrom != nil else { return }
                dragFrom = nil
                let top = CGFloat(max(0, count - 1))
                let vel = -v.velocity.height / pitch            // cards per second
                let coast = vel * 0.22
                let target = min(top, max(0, (spin.pos + coast).rounded()))
                spin.glide(to: target, velocity: spin.pos < 0 || spin.pos > top ? 0 : vel)
            }
    }

    private var composeButton: some View {
        Button { composeOpen = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                Text("Write").font(LetterFont.hand(15)).kerning(1.2)
            }
            .foregroundStyle(scene.page.ink)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background { ClearSheet().clipShape(Capsule()) }
            .overlay(Capsule().stroke(.white.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 22)
        .padding(.bottom, 26)
    }
}

// MARK: - The wheel's own motion

/// Two motions, both pushed frame by frame on springs:
/// - `pos`: which card we're on (fractional while dragging). Follows the
///   finger, keeps its velocity on release, stops dead under a new touch.
/// - `fan`: closed pile 0 <-> fanned arc 1, with a little overshoot, like a
///   deck being shaken open.
@MainActor
final class WheelSpin: ObservableObject {
    @Published private(set) var pos: CGFloat = 0
    @Published private(set) var fan: CGFloat = 0
    /// Which way we're headed (fan itself is fractional and overshoots).
    private(set) var open = false

    private struct Spring {
        var target: CGFloat = 0, vel: CGFloat = 0, live = false
        let k: CGFloat, c: CGFloat
        init(response: CGFloat, damping: CGFloat) {
            k = pow(2 * .pi / response, 2); c = 2 * damping * sqrt(k)
        }
        mutating func step(_ x: inout CGFloat, _ dt: CGFloat) {
            guard live else { return }
            for _ in 0..<2 {   // half-step integration, steadier
                let h = dt / 2
                vel += (-k * (x - target) - c * vel) * h
                x += vel * h
            }
            if abs(x - target) < 0.0015 && abs(vel) < 0.02 { x = target; vel = 0; live = false }
        }
    }
    private var spinS = Spring(response: 0.5, damping: 0.82)
    private var fanS = Spring(response: 0.62, damping: 0.74)
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var tick = 0

    func set(_ p: CGFloat) { pos = p; feel() }

    /// Finger down: stop the spin only; opening/closing finishes on its own.
    func stop() { spinS.live = false; spinS.vel = 0 }

    func glide(to t: CGFloat, velocity v: CGFloat = 0) {
        spinS.target = t; spinS.vel = v; spinS.live = true
        run()
    }

    func setOpen(_ o: Bool) {
        guard o != open else { return }
        open = o
        fanS.target = o ? 1 : 0; fanS.live = true
        run()
    }

    private func run() {
        guard link == nil else { return }
        last = CACurrentMediaTime()
        let l = CADisplayLink(target: Proxy(self), selector: #selector(Proxy.step(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    fileprivate func step(_ l: CADisplayLink) {
        let now = l.targetTimestamp
        var dt = CGFloat(now - last); last = now
        dt = min(max(dt, 0), 1 / 30.0)
        if spinS.live { var p = pos; spinS.step(&p, dt); pos = p; feel() }
        if fanS.live { var f = fan; fanS.step(&f, dt); fan = f }
        if !spinS.live && !fanS.live { link?.invalidate(); link = nil }
    }

    /// A soft tick each time a card passes center.
    private func feel() {
        let t = Int(pos.rounded())
        if t != tick { tick = t; UISelectionFeedbackGenerator().selectionChanged() }
    }

    /// CADisplayLink retains its target; the proxy holds the wheel weakly so
    /// a dismissed wall stops spinning a frame later instead of leaking.
    private final class Proxy: NSObject {
        weak var owner: WheelSpin?
        init(_ o: WheelSpin) { owner = o }
        @objc func step(_ l: CADisplayLink) {
            guard let o = owner else { l.invalidate(); return }
            MainActor.assumeIsolated { o.step(l) }
        }
    }
}

// MARK: - One card on the arc

struct LetterFogCard: View {
    let letter: Letter
    @ObservedObject private var store = LetterStore.shared
    @ObservedObject private var wiped = WipedLetters.shared
    @ObservedObject private var scene = FogScene.shared

    private var clear: Bool { !letter.locked && wiped.ids.contains(letter.id) }

    var body: some View {
        ZStack {
            ClearSheet(card: true)
            if clear { clearFace } else { fogFace }
        }
        .frame(width: LetterWall.cardSize.width, height: LetterWall.cardSize.height)
        .modifier(GlassRim(radius: 26))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    /// Wiped clear: a page of a letter on the sharp scene. A title only if
    /// there is one; the time sits at the bottom, flush right, like a letter.
    private var clearFace: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !letter.title.isEmpty {
                Text(letter.title).font(LetterFont.hand(20)).foregroundStyle(scene.card.ink)
            }
            Text(letter.content)
                .font(LetterFont.hand(15))
                .lineSpacing(6)
                .lineLimit(letter.title.isEmpty ? 5 : 4)
                .foregroundStyle(scene.card.ink.opacity(0.94))
            Spacer(minLength: 0)
            HStack(alignment: .lastTextBaseline) {
                if !letter.replies.isEmpty {
                    Text(letter.replies.count == 1 ? "1 reply" : "\(letter.replies.count) replies")
                        .foregroundStyle(WaxSeal.blue)
                }
                Spacer()
                Text(LetterFormat.when(letter.revealedAt ?? letter.revealAt))
                    .foregroundStyle(scene.card.soft)
            }
            .font(LetterFont.hand(13))
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Still fogged: a full pane of mist. A title only if there is one (and
    /// only once it may travel — locked letters hide it even from the wall's
    /// fog face when the server withheld it); the time at the bottom.
    /// Locked or due is told apart by one thing only: the wax seal. No
    /// "ready!" copy, no "wipe me" copy — the fog is the interface.
    private var fogFace: some View {
        ZStack {
            FogSheet(seed: letter.id, drops: true, card: true)
            VStack(alignment: .leading, spacing: 0) {
                if !letter.locked && !letter.title.isEmpty {
                    Text(letter.title).font(LetterFont.hand(20))
                        .foregroundStyle(scene.card.ink.opacity(0.85))
                }
                Spacer(minLength: 0)
                HStack(alignment: .center, spacing: 9) {
                    if letter.locked { WaxSeal(size: 24) }
                    Spacer(minLength: 0)
                    if letter.locked {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            let left = letter.revealAt - store.now
                            Text("\(LetterFormat.when(letter.revealAt)) · \(left > 0 ? LetterFormat.countdown(left) : "any moment now")")
                                .task(id: left <= 0) {
                                    // Due but still locked here: the server
                                    // reveals on its own timer — ask again.
                                    if left <= 0 { await store.reload() }
                                }
                        }
                    } else {
                        Text(LetterFormat.when(letter.revealedAt ?? letter.revealAt))
                    }
                }
                .font(LetterFont.hand(13))
                .foregroundStyle(scene.card.ink.opacity(0.7))
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
        }
    }
}

// MARK: - The looks panel

/// Pick a photo for the window and/or the cards (kept locally), a veil
/// strength for each, and whether the window itself fogs up. The cards' own
/// fog has no switch — wiping it is the whole point.
struct SkinPanel: View {
    let onClose: () -> Void
    @ObservedObject private var scene = FogScene.shared
    @State private var pagePick: [PhotosPickerItem] = []
    @State private var cardPick: [PhotosPickerItem] = []

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("The wall's looks").font(LetterFont.hand(15)).kerning(1.2)
                    Spacer()
                    Button { onClose() } label: {
                        Text("Done").font(.system(size: 13, weight: .medium))
                            .padding(.vertical, 4).padding(.leading, 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                row("Window", defaultLabel: "Built-in scene", custom: scene.hasCustom(card: false),
                    reset: { scene.clearCustom(card: false) }, pick: $pagePick)
                fogSwitch
                veilSlider(value: $scene.bgVeil)
                row("Cards", defaultLabel: "Same as window", custom: scene.hasCustom(card: true),
                    reset: { scene.clearCustom(card: true) }, pick: $cardPick)
                veilSlider(value: $scene.cardVeil)
            }
            .foregroundStyle(Color(white: 0.95))
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, .dark)
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1))
            .padding(.horizontal, 14).padding(.bottom, 20)
            // The panel eats its own taps so they don't fall through to the
            // close-on-tap layer underneath.
            .contentShape(Rectangle())
            .onTapGesture {}
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
        .transition(.opacity)
        .onChange(of: pagePick) { _, items in Task { await ingest(items, card: false) } }
        .onChange(of: cardPick) { _, items in Task { await ingest(items, card: true) } }
    }

    private func row(_ title: String, defaultLabel: String, custom: Bool,
                     reset: @escaping () -> Void, pick: Binding<[PhotosPickerItem]>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11, weight: .medium)).tracking(2).opacity(0.6)
            HStack(spacing: 8) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    reset()
                } label: { chip(defaultLabel, on: !custom) }
                .buttonStyle(.plain)
                PhotosPicker(selection: pick, maxSelectionCount: 1, matching: .images) {
                    chip(custom ? "Your photo · change" : "Pick a photo", on: custom)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var fogSwitch: some View {
        HStack(spacing: 10) {
            Text("Fog on the window").font(.system(size: 12)).opacity(0.75)
            Spacer()
            // Not a system Toggle: the panel's own tap-eater above swallows
            // Toggle's taps (a Button is unaffected).
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { scene.bgFog.toggle() }
            } label: {
                let on = scene.bgFog
                Capsule().fill(on ? Color.white.opacity(0.82) : Color.white.opacity(0.16))
                    .frame(width: 50, height: 30)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle().fill(on ? Color(white: 0.35) : Color.white.opacity(0.9))
                            .frame(width: 24, height: 24).padding(3)
                    }
                    .padding(.vertical, 4).padding(.leading, 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, -4)
    }

    private func veilSlider(value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text("Veil").font(.system(size: 12)).opacity(0.75)
            Slider(value: value, in: 0...0.8).tint(.white.opacity(0.75))
            Text(String(format: "%.0f%%", value.wrappedValue / 0.8 * 100))
                .font(.system(size: 11)).monospacedDigit().opacity(0.6)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.top, -6)
    }

    private func chip(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(on ? Color.black.opacity(0.8) : Color.white.opacity(0.9))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background {
                if on { Capsule().fill(.white.opacity(0.88)) }
                else { Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.8) }
            }
            .contentShape(Capsule())
    }

    private func ingest(_ items: [PhotosPickerItem], card: Bool) async {
        guard let item = items.first else { return }
        pagePick = []; cardPick = []
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        FogScene.shared.setCustom(data, card: card)
    }
}
