import SwiftUI

// Chat-side rendering — the half of the design that lives in the
// conversation, not on the wall.
//
// In the household this app grew up in, the chat stream tags a message with
// a small letter chip, and the client draws cards instead of ever showing
// the raw fallback text. The rules that survived contact with a real
// recipient:
//
//  - The moment of WRITING is a locked card, and it stays a locked card
//    forever. After the reveal only its countdown line changes (to
//    "developed ›") — the card itself never flips into showing content,
//    because a transcript gets replayed into the agent's context later, and
//    a locked card that flips would leak. No title on it either: the title
//    doesn't travel until the reveal.
//  - The moment of the REVEAL is a second card for the same letter — a
//    tweet-like one: avatar, name, "when · locked for how long", an opened
//    envelope, then title and full text (clamped to ~8 lines in a stream;
//    the wall shows it whole). No footer: at the moment it develops there
//    are exactly zero replies, so a reply count would only ever say 0.
//  - A RETRACTED letter leaves a tombstone line, like any deleted message.
//
// The open-source server has no chat stream, so these ship as reference
// components: hand them a Letter and place them in your own conversation
// UI. CardsDemo below shows all of them on fixture data.

/// The wax seal on everything locked: a round seal with a small heart,
/// beating slowly until the letter develops.
struct WaxSeal: View {
    var size: CGFloat = 34
    /// Developed letters' seals keep still.
    var still = false
    static let wax = Color(red: 0.70, green: 0.36, blue: 0.38)
    static let blue = Color(red: 0.45, green: 0.58, blue: 0.74)
    @State private var beat = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Self.wax.opacity(0.95), Self.wax.opacity(0.72)],
                                     center: .init(x: 0.38, y: 0.32), startRadius: 1, endRadius: size * 0.6))
            Circle().stroke(.white.opacity(0.22), lineWidth: 1).padding(size * 0.12)
            Image(systemName: "heart.fill")
                .font(.system(size: size * 0.34))
                .foregroundStyle(.white.opacity(0.88))
                .scaleEffect(beat ? 1.08 : 0.94)
        }
        .frame(width: size, height: size)
        .shadow(color: Self.wax.opacity(0.35), radius: 4, y: 1)
        .opacity(still ? 0.7 : 1)
        .onAppear {
            guard !still else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { beat = true }
        }
    }
}

/// The locked card: seal + develop time + live countdown. Never a title,
/// never content — this card may be replayed anywhere the transcript goes.
struct LockedChatCard: View {
    let letter: Letter
    @ObservedObject private var store = LetterStore.shared

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            WaxSeal(size: 34, still: !letter.locked)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 8.5, weight: .semibold))
                    Text("a letter · locked").font(.system(size: 10, design: .serif)).tracking(2)
                }
                .foregroundStyle(.secondary)
                Text("develops \(LetterFormat.when(letter.revealAt))")
                    .font(.system(size: 15))
                if letter.locked {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        let left = letter.revealAt - store.now
                        Text(left > 0 ? LetterFormat.countdown(left) : "any moment now")
                            .font(.system(size: 11, design: .serif))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("developed ›")
                        .font(.system(size: 11, design: .serif))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 340, alignment: .leading)
    }
}

/// The reveal card, tweet-style: who wrote it, when it developed and how
/// long it was locked, an opened envelope, then the letter itself.
struct RevealChatCard: View {
    let letter: Letter
    var author = UserDefaults.standard.string(forKey: "lubdub_author") ?? "me"

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 9) {
                avatar
                VStack(alignment: .leading, spacing: 1) {
                    Text(author)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text("\(LetterFormat.when(letter.revealedAt ?? letter.revealAt)) · \(LetterFormat.lockedFor(letter))")
                        .font(.system(size: 10.5, design: .serif))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "envelope.open")
                    .font(.system(size: 13))
                    .foregroundStyle(WaxSeal.wax.opacity(0.8))
            }
            if !letter.title.isEmpty {
                Text(letter.title)
                    .font(.system(size: 16, weight: .semibold))
            }
            Text(letter.content)
                .font(.system(size: 15))
                .lineSpacing(4)
                // In a chat stream the card clamps; the wall reads it whole.
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: 340, alignment: .leading)
    }

    private var avatar: some View {
        Circle()
            .fill(LinearGradient(colors: [WaxSeal.wax.opacity(0.85), WaxSeal.blue.opacity(0.85)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 36, height: 36)
            .overlay {
                Text(String(author.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(.white.opacity(0.92))
            }
    }
}

/// A reply, as a row under a reveal card or on the wall: a thin blue rule,
/// then the words.
struct ReplyChatRow: View {
    let reply: LetterReply

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Capsule().fill(WaxSeal.blue.opacity(0.7)).frame(width: 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("a reply").font(.system(size: 12, design: .serif)).foregroundStyle(WaxSeal.blue)
                    Text(LetterFormat.when(reply.ts)).font(.system(size: 10, design: .serif))
                        .foregroundStyle(.secondary)
                }
                Text(reply.content)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 340, alignment: .leading)
    }
}

/// What a retracted letter leaves behind.
struct LetterTombstone: View {
    var body: some View {
        Text("a letter was taken back")
            .font(.system(size: 11.5, design: .serif)).italic()
            .foregroundStyle(.secondary.opacity(0.8))
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Demo (fixture data, no server needed)

struct CardsDemo: View {
    private static let now = Date().timeIntervalSince1970

    private let locked = Letter(["id": "demo-locked", "ts": now - 1500,
                                 "reveal_at": now + 3 * 3600 + 700, "status": "locked"])!
    private let revealed = Letter(["id": "demo-revealed", "title": "Friday",
                                   "content": "By the time you read this, the week will have done its worst. I wanted one good thing waiting for you at the end of it, so I hid it here on Monday.",
                                   "ts": now - 4 * 86400, "reveal_at": now - 3600,
                                   "revealed_at": now - 3600, "status": "revealed",
                                   "replies": [["id": "r1", "ts": now - 3000,
                                                "content": "It was waiting, and it worked. Monday-you is very good at this."]]])!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                label("the moment of writing — a locked card, forever")
                LockedChatCard(letter: locked)
                label("the same card once the letter has developed")
                LockedChatCard(letter: revealed)
                label("the moment of the reveal — a second card")
                RevealChatCard(letter: revealed)
                label("a reply")
                ReplyChatRow(reply: revealed.replies[0])
                label("a retracted letter")
                LetterTombstone()
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10.5, design: .serif)).tracking(1.5)
            .foregroundStyle(.secondary)
    }
}

#Preview { CardsDemo() }
