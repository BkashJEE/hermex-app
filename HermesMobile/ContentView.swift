import SwiftUI

/// Hermes Mobile is a dedicated thin client for the existing Hermes Desktop
/// gateway. An unpaired phone always lands on the Hermes pairing screen.
struct ContentView: View {
    @Bindable var desktopGatewayAccount: HermesDesktopGatewayAccount

    var body: some View {
        Group {
            if let configuration = desktopGatewayAccount.configuration {
                HermesDesktopGatewayRootView(
                    configuration: configuration,
                    onForget: desktopGatewayAccount.forget
                )
                .id("\(configuration.serverURL.absoluteString)|\(configuration.token.hashValue)")
                .task {
                    await desktopGatewayAccount.refreshServedTokenIfAvailable()
                }
            } else {
                HermesDesktopGatewaySetupView(account: desktopGatewayAccount)
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView(desktopGatewayAccount: HermesDesktopGatewayAccount())
}
