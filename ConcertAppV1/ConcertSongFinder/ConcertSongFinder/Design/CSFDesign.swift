import SwiftUI

enum CSFDesign {
    static let pageBackground = Color(hex: 0x0B0B1E)
    static let surface = Color(hex: 0x1A1533)
    static let raisedSurface = Color(hex: 0x1A1533)
    static let primary = Color(hex: 0xE84393)
    static let violet = Color(hex: 0x8E5CF7)
    static let amber = Color(hex: 0xFFB454)
    static let textPrimary = Color(hex: 0xF5F2FF)
    static let line = textPrimary.opacity(0.12)

    // Semantic aliases keep feature views expressive while staying on-palette.
    static let pink = primary
    static let blue = violet
}

struct CSFScreen<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
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
        .background(CSFDesign.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                .font(.headline.weight(.semibold))
                .foregroundStyle(CSFDesign.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(CSFDesign.textPrimary.opacity(0.64))
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.46), CSFDesign.raisedSurface],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.22))
        }
    }
}

struct CSFMetricGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10)], alignment: .leading, spacing: 10) {
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
                .foregroundStyle(CSFDesign.textPrimary.opacity(0.68))
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
            .foregroundStyle(CSFDesign.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(CSFDesign.primary.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            .background(CSFDesign.raisedSurface.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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
