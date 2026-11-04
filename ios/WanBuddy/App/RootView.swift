import SwiftUI
import WanBuddyCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.isReady {
                WBScreen {
                    ProgressView("読み込み中")
                        .font(.body)
                }
            } else {
                switch model.root {
                case .welcome:
                    WelcomeView()
                case .onboarding:
                    OnboardingView()
                case .main:
                    MainTabView()
                }
            }
        }
        .task {
            if !model.isReady {
                await model.restoreSession()
            }
        }
    }
}
