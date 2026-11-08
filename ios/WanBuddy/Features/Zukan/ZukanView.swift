import SwiftUI
import WanBuddyCore

struct ZukanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            WBScreen {
                Text("大好きな犬友を、もっと身近に。")
                    .font(.title2.weight(.heavy))
                    .fixedSize(horizontal: false, vertical: true)
                InfoBanner(text: "図鑑はまだ準備中です")
            }
            .navigationTitle("図鑑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    EnvironmentBadge(configuration: model.config.configuration)
                }
            }
        }
    }
}
