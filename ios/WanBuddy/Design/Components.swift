import SwiftUI
import WanBuddyCore

struct WanBuddyLogo: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Wan")
                .foregroundStyle(WBColor.ink)
            Text("Buddy")
                .foregroundStyle(WBColor.green)
            Text("●")
                .foregroundStyle(WBColor.coral)
        }
        .font(.title2.weight(.heavy))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("WanBuddy")
    }
}

struct EnvironmentBadge: View {
    let configuration: AppBuildConfiguration

    var body: some View {
        switch configuration {
        case .debug:
            badge("DEV")
        case .beta:
            badge("BETA")
        case .release:
            EmptyView()
        }
    }

    private func badge(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(WBColor.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(WBColor.sage)
            .clipShape(Capsule())
            .accessibilityLabel(title)
    }
}

struct DogAvatar: View {
    let id: String
    var base: CGFloat = 48

    var body: some View {
        Text("🐾")
            .font(.title3)
            .frame(minWidth: base, minHeight: base)
            .background(Color(hexString: AvatarPalette.hex(for: id)))
            .clipShape(Circle())
            .accessibilityLabel("犬のアイコン")
    }
}

struct StatusPill: View {
    enum Tint {
        case sage
        case amber
        case coral
    }

    let text: String
    var tint: Tint = .sage

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(WBColor.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background)
            .clipShape(Capsule())
    }

    private var background: Color {
        switch tint {
        case .sage:
            return WBColor.sage
        case .amber:
            return WBColor.amber
        case .coral:
            return WBColor.coral
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(WBColor.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfoBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(WBColor.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(WBColor.sage)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
