import SwiftUI

// lubdub's reference iOS client: the writer's side.
//
// One screen — the letter wall (LetterWall.swift) — plus a composer, a looks
// panel, a settings sheet for the server address and writer token, and a
// demo of the chat-side cards. Point it at your lubdub (settings, top
// right) and write.

@main
struct LubdubApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @ObservedObject private var store = LetterStore.shared
    @ObservedObject private var scene = FogScene.shared
    @Environment(\.scenePhase) private var phase
    @AppStorage("lubdub_server") private var server = ""
    @State private var settingsOpen = false
    @State private var skinOpen = false
    @State private var demoOpen = false

    var body: some View {
        ZStack {
            LetterWall()
            if skinOpen {
                SkinPanel { withAnimation(.easeOut(duration: 0.2)) { skinOpen = false } }
            }
        }
        .overlay(alignment: .topTrailing) { buttons }
        .sheet(isPresented: $settingsOpen) { SettingsSheet() }
        .sheet(isPresented: $demoOpen) { CardsDemo() }
        .onAppear { if server.isEmpty { settingsOpen = true } }
        .onChange(of: phase) { _, p in
            if p == .active { Task { await store.reload() } }
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            round("bubble.left.and.bubble.right") { demoOpen = true }
            round("photo.on.rectangle") { withAnimation(.easeIn(duration: 0.2)) { skinOpen = true } }
            round("gearshape") { settingsOpen = true }
        }
        .padding(.top, 8)
        .padding(.trailing, 18)
        .opacity(skinOpen ? 0 : 1)
    }

    private func round(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(scene.page.ink)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }
}

struct SettingsSheet: View {
    @AppStorage("lubdub_server") private var server = ""
    @AppStorage("lubdub_token") private var token = ""
    @AppStorage("lubdub_author") private var author = "me"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://lubdub.example.com", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("writer token", text: $token)
                    Text("The writer_token from your server's config.json. The server binds to localhost — put it behind your reverse proxy, or use http://127.0.0.1:7272 from the simulator for a local try. Both values live in UserDefaults; swap in the Keychain if that bothers you.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Reveal card") {
                    TextField("name shown on the card", text: $author)
                }
            }
            .navigationTitle("lubdub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                        Task { await LetterStore.shared.reload() }
                    }
                }
            }
        }
    }
}
