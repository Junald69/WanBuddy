import SwiftUI
import WanBuddyCore

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            WBScreen {
                Text("今日も、わんこと いい一日を。")
                    .font(.title2.weight(.heavy))
                    .fixedSize(horizontal: false, vertical: true)
                Text("今日は誰に会えるかな?")
                    .font(.body)
                    .foregroundStyle(WBColor.ink2)

                #if DEV_LOGIN
                if let ownerID = model.session?.userID, let draft = model.onboarding {
                    CheckInDemoPanel(ownerID: ownerID, dogs: draft.dogs)
                        .id(ownerID)
                }
                #else
                InfoBanner(text: "チェックイン機能は準備中です")
                #endif

                SectionHeader(title: "お友達の予定")
                Text("友達の在場・予定の取得はまだ準備中です")
                    .font(.subheadline)
                    .foregroundStyle(WBColor.ink2)
                Text("お友達との時間を楽しんでね")
                    .font(.caption)
                    .foregroundStyle(WBColor.ink2)
            }
            .navigationTitle("ホーム")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    EnvironmentBadge(configuration: model.config.configuration)
                }
            }
        }
    }
}
