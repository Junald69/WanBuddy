#if DEV_LOGIN
import SwiftUI
import WanBuddyCore

@MainActor
struct CheckInDemoPanel: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var demo: CheckInDemoModel
    @State private var selectedStatus: CheckInSheet?
    @State private var cancellation: CheckInRecord?
    let dogs: [OnboardingDog]

    init(ownerID: String, dogs: [OnboardingDog]) {
        self.dogs = dogs
        _demo = State(initialValue: CheckInDemoModel(ownerID: ownerID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            InfoBanner(text: "モックで試用中です。状態はメモリ内だけに保存され、友達にも送信されません。ログアウト・アプリ再起動で消えます。")
            VStack(alignment: .leading, spacing: 12) {
                Text(demo.facility.name).font(.headline)
                Text("手動チェックイン・利用時間 6:00〜21:00（日本時間）")
                    .font(.subheadline).foregroundStyle(WBColor.ink2)
                if demo.active.isEmpty {
                    Text("チェックインしていません").font(.subheadline)
                }
                ForEach(demo.active) { record in
                    recordCard(record)
                }
                Button("今いるよ") { open(.now) }
                    .buttonStyle(WBPrimaryButtonStyle())
                Button("これから行くよ") { open(.planned) }
                    .buttonStyle(WBSecondaryButtonStyle())
                Text("同じ種類の状態は置き換わります。「今いるよ」を登録すると、この施設の予定は終了します。")
                    .font(.caption).foregroundStyle(WBColor.ink2)
            }
            .wbCard()

            if demo.session.clockWasReset {
                InfoBanner(text: "端末の時刻変更を検知したため、状態を解除しました。時刻を確認して再登録してください。")
            }
            if let ended = demo.latestEnded {
                Text(endedMessage(ended)).font(.subheadline).foregroundStyle(WBColor.ink2)
            }
            if let message = demo.errorMessage {
                Text(message).font(.subheadline).foregroundStyle(WBColor.green2)
            }
            DisclosureGroup("モックの有効期限を試す") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("モック内だけの時刻: \(dateText(demo.now))（日本時間）")
                        .font(.caption)
                    Text("端末の時計やサーバーの時刻は変更しません。進めた時刻は登録・表示にも使います。")
                        .font(.caption).foregroundStyle(WBColor.ink2)
                    Button("モック時刻を1時間進める") { demo.advanceDemo(by: 3600) }
                    Button("モック時刻を3時間進める") { demo.advanceDemo(by: 3 * 3600) }
                    Button("実時刻に戻す（状態を解除）") { demo.returnToRealTime() }
                        .disabled(demo.demoOffset == 0)
                }
                .buttonStyle(WBSecondaryButtonStyle())
                .padding(.top, 8)
            }
            .font(.subheadline)
        }
        .sheet(item: $selectedStatus) { status in
            CheckInDemoForm(demo: demo, status: status.status, dogs: dogs)
        }
        .confirmationDialog("このチェックインを取り消しますか？", isPresented: Binding(
            get: { cancellation != nil }, set: { if !$0 { cancellation = nil } }
        ), titleVisibility: .visible) {
            Button("取り消す", role: .destructive) {
                if let record = cancellation { demo.cancel(record) }
                cancellation = nil
            }
            Button("戻る", role: .cancel) { cancellation = nil }
        }
        .task {
            demo.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                demo.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { demo.refresh() }
        }
    }

    private func open(_ status: CheckInStatus) {
        demo.refresh()
        demo.errorMessage = nil
        selectedStatus = CheckInSheet(status: status)
    }

    private func recordCard(_ record: CheckInRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusPill(text: record.status == .now ? "今いるよ（自分の状態）" : "これから行くよ（予定）",
                       tint: record.status == .now ? .sage : .amber)
            if let planned = record.plannedAt {
                Text("予定: \(dateText(planned))")
            }
            Text("自動解除: \(dateText(record.expiresAt))（日本時間）")
            Text("犬: \(dogs.filter { record.dogIDs.contains($0.id) }.map(\.name).joined(separator: "、"))")
            Text("公開範囲の指定: \(record.visibility == .privateOnly ? "自分のみ" : "友達限定")（モック・未送信）")
            Button("この状態を取り消す") { cancellation = record }
                .buttonStyle(WBSecondaryButtonStyle())
        }
        .font(.subheadline)
        .padding(.vertical, 8)
    }

    private func endedMessage(_ record: CheckInRecord) -> String {
        let title = record.status == .now ? "今いるよ" : "これから行くよ"
        switch record.endedReason {
        case .expired: return "直前の「\(title)」は有効期限が切れました。自動で再登録はしません。"
        case .switchedToNow: return "予定を終了し、「今いるよ」に切り替えました。"
        case .replaced: return "直前の「\(title)」を新しい状態に置き換えました。"
        default: return "直前の「\(title)」を取り消しました。"
        }
    }
}

@MainActor
private struct CheckInDemoForm: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var demo: CheckInDemoModel
    let status: CheckInStatus
    let dogs: [OnboardingDog]
    @State private var selectedDogs: Set<String>
    @State private var visibility: CheckInVisibility = .privateOnly
    @State private var plannedAt: Date

    init(demo: CheckInDemoModel, status: CheckInStatus, dogs: [OnboardingDog]) {
        self.demo = demo
        self.status = status
        self.dogs = dogs
        _selectedDogs = State(initialValue: Set(dogs.map(\.id)))
        _plannedAt = State(initialValue: demo.now.addingTimeInterval(30 * 60))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("モックです。保存しても友達やサーバーへは送信しません。")
                    Text(demo.facility.name)
                }
                Section("一緒に来る犬（1〜5頭）") {
                    ForEach(dogs) { dog in
                        Toggle(dog.name, isOn: Binding(
                            get: { selectedDogs.contains(dog.id) },
                            set: { value in
                                if value { selectedDogs.insert(dog.id) } else { selectedDogs.remove(dog.id) }
                            }
                        ))
                    }
                }
                if status == .planned {
                    Section("予定時刻（日本時間・24時間先まで）") {
                        DatePicker("到着予定", selection: $plannedAt,
                                   in: demo.now...demo.now.addingTimeInterval(CheckInPolicy.maxPlanAhead),
                                   displayedComponents: [.date, .hourAndMinute])
                        Text("予定時刻になっても「今いるよ」には切り替わりません。着いたら手動で登録してください。")
                    }
                }
                Section("公開範囲の指定") {
                    Picker("公開範囲", selection: $visibility) {
                        Text("自分のみ").tag(CheckInVisibility.privateOnly)
                        Text("友達限定").tag(CheckInVisibility.friends)
                    }
                    Text("今回は指定だけを記録します。公開・全員への共有はありません。")
                }
                Section("有効期限") {
                    Text(status == .now
                         ? "登録から最長3時間、または日本時間の閉園21時までです。"
                         : "予定時刻から60分、またはその日の閉園21時までです。")
                    Text("利用時間は6時〜21時。閉園時間外の登録・予定は保存できません。")
                    if let record = preview {
                        Text("保存時点の目安: \(dateText(record.expiresAt))（日本時間）")
                    }
                }
                if let message = demo.errorMessage {
                    Section { Text(message).foregroundStyle(WBColor.green2) }
                }
                Section {
                    Button("モックに保存") {
                        let request = CheckInRequest(status: status, dogIDs: Array(selectedDogs), visibility: visibility,
                                                     plannedAt: status == .planned ? plannedAt : nil)
                        if demo.submit(request, ownedDogIDs: Set(dogs.map(\.id))) { dismiss() }
                    }
                    .disabled(selectedDogs.isEmpty)
                }
            }
            .tint(WBColor.green)
            .navigationTitle(status == .now ? "今いるよ" : "これから行くよ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .environment(\.timeZone, TimeZone(identifier: "Asia/Tokyo") ?? .gmt)
    }

    private var preview: CheckInRecord? {
        try? CheckInPolicy.makeRecord(
            CheckInRequest(status: status, dogIDs: Array(selectedDogs), visibility: visibility,
                           plannedAt: status == .planned ? plannedAt : nil),
            ownerID: demo.session.ownerID, ownedDogIDs: Set(dogs.map(\.id)), facility: demo.facility, now: demo.now
        )
    }
}

private func dateText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.dateFormat = "M月d日 H:mm"
    return formatter.string(from: date)
}

private struct CheckInSheet: Identifiable {
    let status: CheckInStatus
    var id: String { status.rawValue }
}

#Preview("チェックインのモック（認証・DB不要）") {
    NavigationStack {
        WBScreen {
            CheckInDemoPanel(ownerID: "demo-owner", dogs: [
                OnboardingDog(id: "demo-dog", name: "モカ", breed: "柴")
            ])
        }
    }
}
#endif
