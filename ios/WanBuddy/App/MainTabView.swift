import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("ホーム", systemImage: "house") }
            ZukanView()
                .tabItem { Label("図鑑", systemImage: "pawprint") }
            MyPageView()
                .tabItem { Label("マイページ", systemImage: "person.crop.circle") }
        }
        .tint(WBColor.green)
    }
}
