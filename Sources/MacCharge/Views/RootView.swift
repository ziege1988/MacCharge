import SwiftUI

/// Startet mit dem dunkelgrauen Splash (Logo + Version) und wechselt dann zum Dashboard.
struct RootView: View {
    let openSettings: () -> Void
    @State private var showSplash = true

    static let splashDuration: Double = 2.2

    var body: some View {
        ZStack {
            if showSplash {
                SplashView()
                    .transition(.opacity)
            } else {
                DashboardView(openSettings: openSettings)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(width: WidgetWindow.size.width, height: WidgetWindow.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.splashDuration) {
                withAnimation(.easeInOut(duration: 0.5)) { showSplash = false }
            }
        }
    }
}

struct SplashView: View {
    @State private var appear = false

    var body: some View {
        ZStack {
            Theme.splash
            WindowDragArea()
            VStack(spacing: 14) {
                Image(nsImage: AppInfo.logo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 128, height: 128)
                    .shadow(color: Theme.accent.opacity(0.25), radius: 18)
                    .scaleEffect(appear ? 1 : 0.92)
                    .opacity(appear ? 1 : 0)
                Text("Version \(AppInfo.version)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .opacity(appear ? 1 : 0)
            }
            .allowsHitTesting(false)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { appear = true } }
    }
}
