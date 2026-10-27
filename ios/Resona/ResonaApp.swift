import SwiftUI

@main
struct ResonaApp: App {
    @StateObject private var library = LibraryModel()
    @StateObject private var player = PlayerModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainView()
            .environmentObject(library)
            .environmentObject(player)
            .tint(Theme.accent)
            .preferredColorScheme(.light)
            .task {
                player.restorePlayback(session: library.session)
                await library.refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { player.savePlaybackState() }
            }
            .onChange(of: library.session?.token) { _, _ in
                player.connectionChanged(library.session)
            }
        }
    }
}

enum Theme {
    static let paper = Color(red: 0.965, green: 0.957, blue: 0.937)
    static let ink = Color(red: 0.16, green: 0.18, blue: 0.15)
    static let accent = Color(red: 0.77, green: 0.35, blue: 0.22)
    static let sage = Color(red: 0.89, green: 0.92, blue: 0.85)
    static let muted = Color(red: 0.52, green: 0.56, blue: 0.48)
}
