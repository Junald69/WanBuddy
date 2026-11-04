import SwiftUI
import WanBuddyCore

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var nickname = ""
    @State private var dogs: [OnboardingDog] = [
        OnboardingDog(id: UUID().uuidString, name: "", breed: ""),
    ]
    @State private var acceptedTerms = false
    @State private var violations: [OnboardingViolation] = []

    var body: some View {
        WBScreen {
            Text("はじめまして")
                .font(.title2.weight(.heavy))
            Text("ニックネームと、一緒に来る犬を教えてください。")
                .font(.body)
                .foregroundStyle(WBColor.ink2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("ニックネーム")
                    .font(.headline)
                TextField("ニックネーム", text: $nickname)
                    .font(.body)
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .background(WBColor.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(WBColor.border, lineWidth: 1)
                    )
            }

            SectionHeader(title: "犬")
            ForEach($dogs) { $dog in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        DogAvatar(id: dog.id)
                        TextField("犬の名前", text: $dog.name)
                            .font(.body)
                    }
                    TextField("犬種（任意）", text: $dog.breed)
                        .font(.subheadline)
                        .foregroundStyle(WBColor.ink)
                    if dogs.count > 1 {
                        Button("この犬を削除") {
                            dogs.removeAll { $0.id == dog.id }
                        }
                        .font(.subheadline)
                        .foregroundStyle(WBColor.green)
                    }
                }
                .wbCard()
            }

            if dogs.count < OnboardingRules.maxDogs {
                Button("もう1頭追加") {
                    dogs.append(OnboardingDog(id: UUID().uuidString, name: "", breed: ""))
                }
                .buttonStyle(WBSecondaryButtonStyle())
            } else {
                Text("登録できる犬は最大5頭までです")
                    .font(.caption)
                    .foregroundStyle(WBColor.ink2)
            }

            InfoBanner(
                text: "たつみの森ドッグランのご利用には、毎年度(4月1日から)『たつみの森ドッグラン利用登録』が必要です(狂犬病予防注射の接種が前提です)。利用時間は6時〜21時で、夜間照明はありません。"
            )
            Text("WanBuddyはたつみの森ドッグランの公式アプリではありません。")
                .font(.caption)
                .foregroundStyle(WBColor.ink2)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("利用規約とプライバシーポリシーに同意する", isOn: $acceptedTerms)
                .font(.subheadline)
                .tint(WBColor.green)

            if !violations.isEmpty {
                Text(violationSummary)
                    .font(.subheadline)
                    .foregroundStyle(WBColor.green2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("はじめる") {
                let draft = OnboardingDraft(
                    nickname: nickname,
                    dogs: dogs,
                    acceptedTerms: acceptedTerms
                )
                let found = OnboardingValidator.violations(in: draft)
                violations = found
                if found.isEmpty {
                    model.completeOnboarding(draft)
                }
            }
            .buttonStyle(WBPrimaryButtonStyle())
        }
    }

    private var violationSummary: String {
        if violations.contains(.termsNotAccepted) {
            return "利用規約とプライバシーポリシーへの同意が必要です。"
        }
        if violations.contains(.nicknameLength) {
            return "ニックネームは1〜20文字にしてください。"
        }
        if violations.contains(.dogCount) || violations.contains(where: {
            if case .dogNameLength = $0 { return true }
            return false
        }) {
            return "犬の名前を1頭以上、30文字以内で入力してください。"
        }
        return "入力内容を確認してください。"
    }
}
