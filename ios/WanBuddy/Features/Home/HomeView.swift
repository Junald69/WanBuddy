import SwiftUI
import WanBuddyCore

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showComingSoon = false

    var body: some View {
        NavigationStack {
            WBScreen {
                Text("今日も、わんこと いい一日を。")
                    .font(.title2.weight(.heavy))
                    .fixedSize(horizontal: false, vertical: true)
                Text("今日は誰に会えるかな?")
                    .font(.body)
                    .foregroundStyle(WBColor.ink2)

                VStack(alignment: .leading, spacing: 12) {
                    Text("たつみの森ドッグラン")
                        .font(.headline)
                    Text("着いたらボタンを押してね")
                        .font(.subheadline)
                        .foregroundStyle(WBColor.ink2)
                    StatusPill(text: "いまいるよ 0")
                    Button("今いるよ") { showComingSoon = true }
                        .buttonStyle(WBPrimaryButtonStyle())
                    Button("これから行くよ") { showComingSoon = true }
                        .buttonStyle(WBSecondaryButtonStyle())
                }
                .wbCard()

                SectionHeader(title: "お友達の予定")
                Text("まだお友達の予定はありません")
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
            .sheet(isPresented: $showComingSoon) {
                NavigationStack {
                    WBScreen {
                        Text("この機能はまだ準備中です")
                            .font(.title2.weight(.heavy))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("着いたらボタンを押してね")
                            .font(.body)
                            .foregroundStyle(WBColor.ink2)
                    }
                    .navigationTitle("今いるよ")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("閉じる") { showComingSoon = false }
                        }
                    }
                }
            }
        }
    }
}
