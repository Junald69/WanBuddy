#if DEV_LOGIN
import SwiftUI

struct DevLoginView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            WBScreen {
                Text("開発環境のテストユーザーでサインインします。")
                    .font(.subheadline)
                    .foregroundStyle(WBColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("メールアドレス", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body)
                    .padding(12)
                    .background(WBColor.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(WBColor.border, lineWidth: 1)
                    )
                SecureField("パスワード", text: $password)
                    .textContentType(.password)
                    .font(.body)
                    .padding(12)
                    .background(WBColor.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(WBColor.border, lineWidth: 1)
                    )
                if let message = model.authErrorMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(WBColor.green2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task {
                        await model.signInWithEmail(email: email, password: password)
                        if model.session != nil {
                            dismiss()
                        }
                    }
                } label: {
                    if model.isSigningIn {
                        ProgressView()
                            .tint(WBColor.white)
                    } else {
                        Text("ログイン")
                    }
                }
                .buttonStyle(WBPrimaryButtonStyle())
                .disabled(model.isSigningIn)
            }
            .navigationTitle("開発用ログイン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
#endif
