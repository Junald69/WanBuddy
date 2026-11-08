public enum SignInFailureMessage {
    public static let invalidCredentials = "メールアドレスまたはパスワードが違います"
    public static let generic = "ログインできませんでした。時間をおいてもう一度お試しください"

    public static func message(forServerText text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("invalid") || lower.contains("credentials") {
            return invalidCredentials
        }
        if lower.contains("email") && lower.contains("password") {
            return invalidCredentials
        }
        return generic
    }
}
