import SwiftUI
import WanBuddyCore

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showDevLogin = false
    @State private var showUnavailable = false

    var body: some View {
        welcome.sheet(isPresented: $showDevLogin) {
            loginSheet
        }
    }

    private var welcome: some View {
        WBScreen {
            HStack {
                WanBuddyLogo()
                Spacer()
                EnvironmentBadge(configuration: model.config.configuration)
            }
            Text("わんこと、もっとつながろう。")
                .font(.title2.weight(.heavy))
                .fixedSize(horizontal: false, vertical: true)
            Text("ドッグランで会う犬友と、今いるよを分けあうアプリです。")
                .font(.body)
                .foregroundStyle(WBColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            InfoBanner(text: "友達限定・手動チェックイン・時間で自動解除。位置情報は使いません。")
            Button(action: signInTapped) {
                Label("Appleでサインイン", systemImage: "apple.logo")
            }
            .buttonStyle(WBPrimaryButtonStyle())
            if showUnavailable {
                Text("Appleでサインインは、Apple Developer Program加入後に使えるようになります。")
                    .font(.subheadline)
                    .foregroundStyle(WBColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var loginSheet: some View {
        #if DEV_LOGIN
        DevLoginView()
        #else
        EmptyView()
        #endif
    }

    private func signInTapped() {
        #if DEV_LOGIN
        showDevLogin = true
        #else
        showUnavailable = true
        #endif
    }
}
