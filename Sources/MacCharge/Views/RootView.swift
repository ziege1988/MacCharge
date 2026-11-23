import SwiftUI

/// Startet mit dem dunkelgrauen Splash (Logo + Version) und wechselt dann zum Dashboard.
struct RootView: View {
    let openSettings: () -> Void
    @EnvironmentObject var settings: AppSettings
    @State private var showSplash = true

    static let splashDuration: Double = 2.2

    var body: some View {
        let layout = settings.layout
        ZStack {
            if showSplash {
                SplashView(layout: layout)
                    .transition(.opacity)
            } else if layout == .bar {
                BarDashboardView(openSettings: openSettings)
                    .transition(.opacity)
            } else {
                DashboardView(openSettings: openSettings)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .clipShape(RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.splashDuration) {
                withAnimation(.easeInOut(duration: 0.5)) { showSplash = false }
            }
        }
    }
}

struct SplashView: View {
    var layout: WidgetLayout = .tall
    @State private var appear = false

    var body: some View {
        ZStack {
            Theme.splash
            WindowDragArea()
            Group {
                if layout == .bar {
                    HStack(spacing: 12) {
                        logo(size: 44)
                        BrandText(size: 20)
                        version
                    }
                } else {
                    VStack(spacing: 14) {
                        logo(size: 128)
                        version
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { appear = true } }
    }

    private func logo(size: CGFloat) -> some View {
        Image(nsImage: AppInfo.logo)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(color: Theme.accent.opacity(0.25), radius: size / 7)
            .scaleEffect(appear ? 1 : 0.92)
            .opacity(appear ? 1 : 0)
    }

    private var version: some View {
        Text("Version \(AppInfo.version)")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
            .opacity(appear ? 1 : 0)
    }
}
