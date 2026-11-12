import SwiftUI

// Writing a letter. Two ways to pick the reveal, same as the API: a
// duration ("in a while" -> lock_for) or an exact moment ("at a time" ->
// reveal_at). The line at the bottom always shows the resulting develop
// time, and server-side errors land on the page verbatim.

struct Composer: View {
    @ObservedObject private var store = LetterStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var text = ""
    /// true = "in a while" (lock_for), false = "at a time" (reveal_at)
    @State private var byDuration = true
    @State private var lockFor = "3h"
    @State private var at = Date().addingTimeInterval(86400)
    @FocusState private var focused: Bool

    private static let quick: [(String, String)] = [("1h", "1 hour"), ("3h", "3 hours"), ("12h", "12 hours"),
                                                    ("1d", "1 day"), ("3d", "3 days"), ("7d", "7 days")]

    // Server default min_lock_minutes is 5; it rejects anything closer
    // anyway, this just keeps the picker honest.
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.posting
            && (byDuration || at.timeIntervalSinceNow > 240)
    }

    private var revealDate: Date {
        byDuration ? Date().addingTimeInterval(LetterStore.seconds(lockFor)) : at
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    bar
                    TextField("Title (optional — it travels only at the reveal)", text: $title)
                        .font(LetterFont.hand(15))
                        .padding(.horizontal, 13).padding(.vertical, 11)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 11))
                        .onChange(of: title) { _, v in if v.count > 80 { title = String(v.prefix(80)) } }
                    editor
                    timePicker
                    Text("Your agent is told at once that a letter exists — and when it develops. Nothing else travels until then, the title included. Once it has read you, it can write back.")
                        .font(.system(size: 12))
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)
                    if let err = store.error {
                        Text(err).font(.system(size: 12.5)).foregroundStyle(WaxSeal.wax)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear { store.error = nil; focused = true }
    }

    private var bar: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer()
            Text("a letter")
                .font(.system(size: 11, design: .serif)).tracking(3)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                let ti = title, tx = text
                let rv: LetterStore.Reveal = byDuration ? .after(lockFor) : .at(at)
                Task { if await store.create(title: ti, content: tx, reveal: rv) { dismiss() } }
            } label: {
                if store.posting {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill").font(.system(size: 11))
                        Text("Lock")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(canSend ? WaxSeal.wax : Color.secondary.opacity(0.5))
                }
            }
            .disabled(!canSend)
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Write now. It develops later.")
                    .font(LetterFont.hand(16))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .padding(.horizontal, 18).padding(.vertical, 19)
            }
            TextEditor(text: $text)
                .font(LetterFont.hand(16))
                .lineSpacing(6)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 13).padding(.vertical, 11)
                .onChange(of: text) { _, v in if v.count > 4000 { text = String(v.prefix(4000)) } }
        }
        .frame(height: 250)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))
    }

    private var timePicker: some View {
        VStack(alignment: .leading, spacing: 11) {
            Picker("", selection: $byDuration) {
                Text("In a while").tag(true)
                Text("At a time").tag(false)
            }
            .pickerStyle(.segmented)
            if byDuration {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(Self.quick, id: \.0) { k, label in
                        let on = lockFor == k
                        Button { lockFor = k } label: {
                            Text(label)
                                .font(.system(size: 13.5))
                                .foregroundStyle(on ? Color.white : Color.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(on ? AnyShapeStyle(WaxSeal.wax.opacity(0.85))
                                               : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                DatePicker("Develops", selection: $at, in: Date().addingTimeInterval(300)...,
                           displayedComponents: [.date, .hourAndMinute])
                    .font(.system(size: 14))
            }
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text("develops \(LetterFormat.when(revealDate.timeIntervalSince1970))")
            }
            .font(.system(size: 13))
            .foregroundStyle(WaxSeal.wax)
        }
        .padding(13)
        .background(Color(.secondarySystemGroupedBackground).opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 13))
    }
}
