import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Longhaul", systemImage: "bolt.shield").font(.largeTitle.weight(.semibold))
            Text("Let your work finish.").font(.title2)
            Label("Protect supported jobs automatically", systemImage: "checkmark.circle")
            Label("Save recoverable progress before power runs low", systemImage: "externaldrive.badge.checkmark")
            Label("Return to normal sleep when work finishes", systemImage: "moon")
            Text("Connect an integration in Settings and verify a live job appears in Activity. Enable closed-lid protection in Settings and check its live status before closing the lid. The display may turn off; desktop agents need their own supported locked-use capability.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Start at Login") { model.setLogin(true) }.disabled(!model.canConfigure)
                Spacer()
                Button("Get Started") { model.finishOnboarding(); model.navigate(to: .integrations) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(maxWidth: 650, maxHeight: .infinity, alignment: .center)
    }
}
