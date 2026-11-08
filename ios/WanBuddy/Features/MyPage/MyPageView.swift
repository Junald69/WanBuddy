import SwiftUI
import WanBuddyCore

struct MyPageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            WBScreen {
                HStack(spacing: 12) {
                    DogAvatar(id: model.session?.userID ?? "me", base: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.onboarding?.nickname ?? "ニックネーム未設定")
                            .font(.title2.weight(.heavy))
                        if let email = model.session?.email {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(WBColor.ink2)
                        }
                    }
                }
                if let dogs = model.onboarding?.dogs, !dogs.isEmpty {
                    SectionHeader(title: "うちの子")
                    ForEach(dogs) { dog in
                        HStack(spacing: 12) {
                            DogAvatar(id: dog.id)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dog.name)
                                    .font(.headline)
                                if !dog.breed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(dog.breed)
                                        .font(.subheadline)
                                        .foregroundStyle(WBColor.ink2)
                                }
                            }
                        }
                        .wbCard()
                    }
                }
                Text("わんこらしく、自分らしく。")
                    .font(.subheadline)
                    .foregroundStyle(WBColor.ink2)
                Button("ログアウト") {
                    Task { await model.signOut() }
                }
                .buttonStyle(WBSecondaryButtonStyle())
            }
            .navigationTitle("マイページ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    EnvironmentBadge(configuration: model.config.configuration)
                }
            }
        }
    }
}
