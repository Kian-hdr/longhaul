import SwiftUI
import AppKit

struct AboutView: View {
    @State private var showingLicense = false

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info["CFBundleVersion"] as? String ?? "Unknown"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Longhaul").font(.title2.weight(.semibold))
                        Text(version).foregroundStyle(.secondary)
                        Text("Let your work finish.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
                LabeledContent("Created by", value: "Kian Konrad Tajbakhsh")
                    .textSelection(.enabled)
            }
            Section("License") {
                LabeledContent("License", value: "GNU GPLv3")
                Text("You may share and modify Longhaul under the GNU General Public License, version 3. Longhaul comes without any warranty.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Read License…") { showingLicense = true }
            }
            Section("Project") {
                Link("Source and Support", destination: URL(string: "https://github.com/Kian-hdr/longhaul")!)
                Link("Releases", destination: URL(string: "https://github.com/Kian-hdr/longhaul/releases")!)
            }
            Section {
                Text("© 2026 Kian Konrad")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingLicense) { LicenseView() }
    }
}

private struct LicenseView: View {
    @Environment(\.dismiss) private var dismiss
    private static let license: String? = {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("GNU General Public License")
                .font(.headline).accessibilityAddTraits(.isHeader)
            ScrollView {
                if let license = Self.license {
                    Text(license)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("The bundled license could not be loaded.")
                    Link("Read GPLv3 on gnu.org", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500, height: 360)
        .onExitCommand { dismiss() }
    }
}
