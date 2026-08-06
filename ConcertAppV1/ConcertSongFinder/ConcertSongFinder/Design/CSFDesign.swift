import SwiftUI

enum CSFDesign {
    static let pageBackground = Color(hex: 0x0B0D0F)
    static let surface = Color(hex: 0x16191E)
    static let raisedSurface = Color(hex: 0x2A2F37)
    static let deepSurface = Color(hex: 0x0B0D0F)
    static let primary = Color(hex: 0xCCFF00)
    static let violet = Color(hex: 0x2C351E)
    static let amber = Color(hex: 0xCCFF00)
    static let textPrimary = Color(hex: 0xEAECEF)
    static let textMuted = Color(hex: 0x8E9AA8)
    static let line = Color(hex: 0x2A2F37)
    static let cardRadius: CGFloat = 22
    static let controlRadius: CGFloat = 18

    // Semantic aliases keep feature views expressive while staying on-palette.
    static let pink = primary
    static let blue = violet
    static let accentAcid = primary
    static let accentMud = violet
    static let border = line

    static var stageWash: LinearGradient {
        LinearGradient(
            colors: [accentMud.opacity(0.82), accentAcid.opacity(0.26), pageBackground.opacity(0.06)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct CSFScreen<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(.horizontal, 23)
            .padding(.top, 76)
            .padding(.bottom, 120)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .background(CSFDesign.pageBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

struct CSFCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CSFDesign.surface, in: RoundedRectangle(cornerRadius: CSFDesign.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CSFDesign.cardRadius, style: .continuous)
                .stroke(CSFDesign.line)
        }
    }
}

struct CSFSectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(3)
                .foregroundStyle(CSFDesign.textMuted)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(CSFDesign.textMuted)
            }
        }
    }
}

struct CSFMetricTile: View {
    let title: String
    let value: String
    let icon: String
    var tint: Color = CSFDesign.primary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(CSFDesign.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(CSFDesign.textPrimary.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(14)
        .frame(minHeight: 112, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: CSFDesign.controlRadius, style: .continuous)
                .fill(CSFDesign.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: CSFDesign.controlRadius, style: .continuous)
                .stroke(tint.opacity(0.22))
        }
    }
}

struct CSFMetricGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], alignment: .leading, spacing: 10) {
            content
        }
    }
}

struct CSFHeroLead: View {
    let icon: String
    let title: String
    let subtitle: String
    var tint: Color = CSFDesign.primary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CSFEmptyStateIcon(systemName: icon, tint: tint)
            text
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(CSFDesign.textPrimary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(CSFDesign.textMuted)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CSFStatusChip: View {
    let text: String
    let icon: String
    var tint: Color = CSFDesign.primary

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay {
                Capsule().stroke(tint.opacity(0.24))
            }
    }
}

struct CSFPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(CSFDesign.pageBackground)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(CSFDesign.primary.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: CSFDesign.controlRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct CSFSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(CSFDesign.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(CSFDesign.raisedSurface.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: CSFDesign.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CSFDesign.controlRadius, style: .continuous)
                    .stroke(CSFDesign.line)
            }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct CSFEmptyStateIcon: View {
    let systemName: String
    var tint: Color = CSFDesign.primary

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.16))
                .frame(width: 64, height: 64)
            Image(systemName: systemName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

extension View {
    func csfListChrome() -> some View {
        scrollContentBackground(.hidden)
            .background(CSFDesign.pageBackground)
            .foregroundStyle(CSFDesign.textPrimary)
            .tint(CSFDesign.primary)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }

    func csfPageChrome() -> some View {
        background(CSFDesign.pageBackground)
            .foregroundStyle(CSFDesign.textPrimary)
            .tint(CSFDesign.primary)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

struct CSFSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(CSFDesign.textMuted)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(CSFDesign.textPrimary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(CSFDesign.surface, in: RoundedRectangle(cornerRadius: CSFDesign.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CSFDesign.cardRadius, style: .continuous)
                .stroke(CSFDesign.line)
        }
    }
}

struct StagePoster: View {
    var body: some View {
        ZStack {
            CSFDesign.stageWash
            LinearGradient(
                colors: [.clear, CSFDesign.pageBackground.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack {
                HStack(spacing: 18) {
                    ForEach(0..<4, id: \.self) { _ in
                        Capsule()
                            .fill(CSFDesign.textPrimary.opacity(0.28))
                            .frame(width: 10, height: 26)
                            .blur(radius: 5)
                    }
                }
                Spacer()
            }
            .padding(.top, 18)
        }
    }
}
