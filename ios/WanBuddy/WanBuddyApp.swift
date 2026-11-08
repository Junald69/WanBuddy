import SwiftUI

@main
struct WanBuddyApp: App {
    @State private var model: AppModel

    init() {
        let config = ConfigBootstrap.loadOrStop()
        _model = State(initialValue: AppModel(config: config))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.light)
        }
    }
}
