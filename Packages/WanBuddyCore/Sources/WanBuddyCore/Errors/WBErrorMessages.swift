import Foundation

/// Maps Postgres SQLSTATE codes raised by WanBuddy (`WBxxx`) to Japanese UI copy.
public enum WBErrorMessages {
    public static func message(forCode code: String) -> String {
        switch code {
        case "WB001":
            return "このQRコードは使用できません"
        case "WB002":
            return "自分自身には登録できません"
        case "WB003":
            return "すでに友達です"
        case "WB004":
            return "本日のQR登録の上限に達しました"
        case "WB005":
            return "友達の上限に達しています"
        case "WB006":
            return "すでに申請済みです"
        case "WB007":
            return "QRでの友達登録を受け付けない設定になっています"
        case "WB009":
            return "承認できません"
        case "WB011":
            return "コードが見つかりません"
        case "WB013":
            return "この相手には申請できません"
        case "WB014":
            return "未承認の申請が多すぎます。相手の承認を待ってください"
        case "WB015":
            return "申請が見つかりません"
        case "WB101":
            return "施設が見つかりません"
        case "WB102":
            return "犬を1頭以上選んでください"
        case "WB103":
            return "自分の犬のみ選べます"
        case "WB104":
            return "状態の指定が正しくありません"
        case "WB105":
            return "予定時刻を指定してください"
        case "WB106":
            return "公開範囲の指定が正しくありません"
        case "WB107":
            return "登録できる犬は最大5頭までです"
        case "WB108":
            return "最後の1頭は削除できません"
        case "WB201":
            return "ドッグランの利用時間(6時〜21時)外です"
        case "WB202":
            return "エリアが見つかりません"
        case "WB203":
            return "予定時刻が過去です"
        case "WB204":
            return "予定は24時間先までです"
        case "WB205":
            return "閉園時刻を超えて延長できません"
        case "WB206":
            return "この在場は変更できません"
        case "WB207":
            return "在場が見つかりません"
        case "WB301":
            return "本日の通報の上限に達しました"
        case "WB302":
            return "本日の意見送信の上限に達しました"
        case "WB401":
            return "ログインが必要です"
        case "WB402":
            return "プロフィールを作成してください"
        case "WB500":
            return "処理を完了できませんでした"
        default:
            return generic
        }
    }

    /// Pulls the first `WBxxx` code out of a server or SDK error description.
    public static func message(extractingFrom text: String) -> String {
        guard let range = text.range(of: "WB[0-9]{3}", options: .regularExpression) else {
            return generic
        }
        return message(forCode: String(text[range]))
    }

    public static let generic = "処理を完了できませんでした。時間をおいてもう一度お試しください"
}
