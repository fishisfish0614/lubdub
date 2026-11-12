import SwiftUI
import UIKit

// The pulled-out card: one big pane of misted glass, wiped with a finger.
//
// Developed letter: wipe strokes stay; once about half the pane is covered
// the whole fog dissolves and the letter reads like a page — title (if any),
// body, time flush right, replies following as their own short pages. The
// wipe is remembered locally, so next time the card is already clear.
//
// Locked letter: you can thin the fog a little, it holds for a moment, then
// settles back. Nothing is under it — the body never travels to this face —
// and the only words the page ever says are "not yet".

/// One wipe stroke; when the finger lifts, a run of water drips from its
/// lowest point.
struct FogStroke {
    var pts: [CGPoint]
    var last: Date
    var drip: (from: CGPoint, start: Date, len: CGFloat)?
}

struct WipeOverlay: View {
    let letter: Letter
    let onClose: () -> Void
    @ObservedObject private var wiped = WipedLetters.shared
    @ObservedObject private var scene = FogScene.shared

    @State private var strokes: [FogStroke] = []
    @State private var cells: Set<Int> = []
    @State private var cleared = false
    @State private var nudge = false          // locked + wiped: the line below shivers
    @State private var shown = false

    private let cols = 9, rows = 12
    private let brush: CGFloat = 64
    /// A locked letter's wipe: hold a moment, then the fog settles back
    /// slowly. (Fast re-fogging feels like being told off.)
    private let refogHold: Double = 1.2
    private let refogFade: Double = 3.2
    private var refog: Double { refogHold + refogFade }

    // Pulled out, the card takes most of the screen; a long letter scrolls
    // inside (only after it's been wiped clear).
    private var paneW: CGFloat { UIScreen.main.bounds.width - 28 }
    private var paneH: CGFloat { min(720, UIScreen.main.bounds.height * 0.75) }

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.38 : 0)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                pane
                    .overlay(alignment: .topTrailing) { closeButton }
                Text("not yet — the fog closed back over")
                    .font(.system(size: 11, design: .serif)).tracking(2)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .opacity(nudge ? 1 : 0)
                    .offset(x: nudge ? 5 : 0)
            }
            // Grows out of the arc's centered card: starts at card size,
            // then scales up into place.
            .scaleEffect(shown ? 1 : LetterWall.cardSize.width / paneW)
            .offset(x: shown ? 0 : -UIScreen.main.bounds.width * 0.03,
                    y: shown ? 0 : -UIScreen.main.bounds.height * 0.03)
            .opacity(shown ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The tap target is the whole layer, not the dark backdrop (a tap
        // handler on the Color alone can end up unreachable). While fog
        // remains, the pane's own wipe gesture wins; once it's gone, a tap
        // anywhere puts the card back.
        .contentShape(Rectangle())
        .onTapGesture { close() }
        .onAppear {
            cleared = !letter.locked && wiped.ids.contains(letter.id)
            withAnimation(.spring(response: 0.46, dampingFraction: 0.8)) { shown = true }
        }
    }

    private var closeButton: some View {
        Button { close() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.28), in: Circle())
                .padding(12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pane: some View {
        ScrollView(showsIndicators: false) {
            // A page of a letter: title only if there is one, the body, the
            // time flush right just under it (not pinned to the bottom —
            // that would drop a short letter's replies too far down), then
            // each reply as its own short page with a signing-off line.
            VStack(alignment: .leading, spacing: 14) {
                // A locked letter puts nothing under the fog — even a
                // thinned wipe shows only the scene behind it.
                if !letter.locked {
                    if !letter.title.isEmpty {
                        Text(letter.title).font(LetterFont.hand(26)).foregroundStyle(scene.card.ink)
                            .padding(.bottom, 2)
                    }
                    Text(letter.content)
                        .font(LetterFont.hand(19))
                        .lineSpacing(9)
                        .foregroundStyle(scene.card.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(LetterFormat.when(letter.revealedAt ?? letter.revealAt))
                        .font(LetterFont.hand(14)).foregroundStyle(scene.card.soft)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    ForEach(letter.replies) { r in
                        Rectangle().fill(scene.card.ink.opacity(0.14)).frame(height: 0.5)
                            .padding(.vertical, 6)
                        Text(r.content)
                            .font(LetterFont.hand(18))
                            .lineSpacing(8)
                            .foregroundStyle(scene.card.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("— a reply · \(LetterFormat.when(r.ts))")
                            .font(LetterFont.hand(14)).foregroundStyle(WaxSeal.blue)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 26).padding(.top, 30).padding(.bottom, 24)
            .frame(maxWidth: .infinity, minHeight: paneH, alignment: .topLeading)
        }
        .scrollDisabled(!cleared)   // while fogged, the finger wipes, it doesn't scroll
        .frame(width: paneW, height: paneH)
        .background(ClearSheet(card: true))
        .overlay {
            fog
                .opacity(cleared ? 0 : 1)
                .allowsHitTesting(!cleared)
        }
        .modifier(GlassRim(radius: 34))
    }

    private var fog: some View {
        TimelineView(.animation) { tl in
            FogSheet(seed: letter.id + "-big", drops: true, card: true)
                .mask {
                    Canvas { ctx, size in
                        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                        ctx.blendMode = .destinationOut
                        for s in strokes {
                            let age = tl.date.timeIntervalSince(s.last)
                            // Locked: a stroke only thins the fog (70%) and
                            // heals after a hold. Developed: it cuts clean
                            // and stays.
                            let k: Double = letter.locked
                                ? (age < refogHold ? 1 : max(0, 1 - (age - refogHold) / refogFade)) * 0.7
                                : 1
                            guard k > 0.01 else { continue }
                            var p = Path()
                            if s.pts.count == 1 {
                                p.addEllipse(in: CGRect(x: s.pts[0].x - 1, y: s.pts[0].y - 1, width: 2, height: 2))
                            } else {
                                p.addLines(s.pts)
                            }
                            ctx.stroke(p, with: .color(.white.opacity(k)),
                                       style: .init(lineWidth: brush, lineCap: .round, lineJoin: .round))
                            if let d = s.drip {
                                let run = min(d.len, CGFloat(tl.date.timeIntervalSince(d.start)) * 46)
                                var line = Path()
                                line.move(to: d.from)
                                line.addLine(to: CGPoint(x: d.from.x, y: d.from.y + run))
                                ctx.stroke(line, with: .color(.white.opacity(k)),
                                           style: .init(lineWidth: 6, lineCap: .round))
                                ctx.fill(Path(ellipseIn: CGRect(x: d.from.x - 5, y: d.from.y + run - 5,
                                                                width: 10, height: 13)),
                                         with: .color(.white.opacity(k)))
                            }
                        }
                    }
                    .blur(radius: 5)   // soft-edged strokes
                }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in touch(v.location, first: v.translation == .zero) }
                .onEnded { v in lift(v.location) }
        )
    }

    private func touch(_ p: CGPoint, first: Bool) {
        let now = Date()
        if first || strokes.isEmpty {
            strokes.append(FogStroke(pts: [p], last: now))
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        } else {
            strokes[strokes.count - 1].pts.append(p)
            strokes[strokes.count - 1].last = now
        }
        guard !letter.locked else { return }
        // Track which grid cells this stroke covered; half the pane = clear.
        let cw = paneW / CGFloat(cols), ch = paneH / CGFloat(rows)
        let r = brush / 2
        let x0 = Int(max(0, (p.x - r) / cw)), x1 = Int(min(CGFloat(cols - 1), max(0, (p.x + r) / cw)))
        let y0 = Int(max(0, (p.y - r) / ch)), y1 = Int(min(CGFloat(rows - 1), max(0, (p.y + r) / ch)))
        guard x0 <= x1, y0 <= y1 else { return }
        for cx in x0...x1 { for cy in y0...y1 { cells.insert(cy * cols + cx) } }
    }

    private func lift(_ p: CGPoint) {
        guard !strokes.isEmpty else { return }
        if letter.locked {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.3)) { nudge = true }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation { nudge = false }
                let cut = Date().addingTimeInterval(-refog)
                strokes.removeAll { $0.last < cut }
            }
            return
        }
        // Where the finger lifts, a run of water slides down.
        let low = strokes[strokes.count - 1].pts.max(by: { $0.y < $1.y }) ?? p
        strokes[strokes.count - 1].drip = (CGPoint(x: low.x, y: low.y + brush * 0.3), Date(),
                                           CGFloat.random(in: 40...120))
        if Double(cells.count) / Double(cols * rows) >= 0.5 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.easeOut(duration: 1.4)) { cleared = true }
            wiped.mark(letter.id)
        }
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.22)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { onClose() }
    }
}
