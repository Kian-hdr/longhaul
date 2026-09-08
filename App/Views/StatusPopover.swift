import SwiftUI
import LonghaulCore

/// A compact control surface. The NSPopover owns its material and outer chrome.
struct StatusPopover: View {
    let openMain: (_ settings: Bool) -> Void
    @Environment(AppModel.self) private var model
    @State private var hoveredAction: String?

    private var currentJobs: [TrackedJob] {
        model.jobs.filter { !$0.event.phase.isTerminal }
    }

    var body: some View {
        VStack(spacing: 0) {
            status
                .padding(16)

            VStack(alignment: .leading, spacing: 6) {
                Label(model.lidProtection.title, systemImage: "laptopcomputer")
                if model.codexReportingUnconfirmed {
                    Text("No active Codex job reported")
                    Button("Check Integration…") {
                        openMain(false)
                        model.navigate(to: .integrations)
                    }
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 12)

            if let countdown = model.sleepCountdown {
                HStack(spacing: 8) {
                    Label("Sleeping in \(countdown)s", systemImage: "moon.zzz")
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Button("Cancel") { model.cancelSleep() }
                        .controlSize(.small)
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            if !currentJobs.isEmpty {
                jobs
            }

            Divider().padding(.horizontal, 16)

            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    rowLabel("Automatic protection", symbol: "bolt.shield")
                    Spacer(minLength: 0)
                    Toggle("Automatic protection", isOn: Binding(
                        get: { model.settings.enabled },
                        set: { enabled in
                            if enabled != model.settings.enabled { model.toggleAutomation() }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Prevent idle sleep for reported jobs. Closing the lid can still pause work.")
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 32)

                HStack(spacing: 8) {
                    rowLabel("Keep Awake", symbol: "timer")
                    Spacer(minLength: 0)
                    Menu("Duration…") {
                        Button("30 Minutes") { model.keepAwake(minutes: 30) }
                        Button("1 Hour") { model.keepAwake(minutes: 60) }
                        Button("4 Hours") { model.keepAwake(minutes: 240) }
                        if currentJobs.contains(where: { $0.event.source == "Manual" }) {
                            Divider()
                            Button("End Manual Session") { model.endManual() }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel("Keep Awake duration")
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 32)
            }
            .padding(8)

            Divider().padding(.horizontal, 16)

            VStack(spacing: 2) {
                action("Open Longhaul", symbol: "macwindow") { openMain(false) }
                action("Settings…", symbol: "gearshape", shortcut: "⌘,") { openMain(true) }
                Divider().padding(.horizontal, 8).padding(.vertical, 4)
                action("Quit Longhaul", symbol: "power", shortcut: "⌘Q") {
                    model.stop()
                    NSApp.terminate(nil)
                }
            }
            .padding(8)
        }
        .font(.body)
        .frame(width: 304)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: model.symbol)
                    .font(.system(size: 26, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(model.isHolding ? Color.accentColor : Color.primary)
                    .frame(width: 32, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Longhaul").font(.headline)
                    Text(model.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Image(systemName: model.power.onAC ? "powerplug" : "battery.100percent")
                    .accessibilityHidden(true)
                Text(model.batteryText).monospacedDigit()
                Spacer(minLength: 8)
                Text(model.sourceText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private var jobs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current work").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ForEach(currentJobs.prefix(3)) { job in
                HStack(spacing: 8) {
                    Image(systemName: job.stale ? "exclamationmark.circle" : "bolt.shield")
                        .foregroundStyle(.secondary)
                    Text(job.event.title).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let progress = job.event.progress {
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .help(job.event.title)
            }
            if currentJobs.count > 3 {
                Text("\(currentJobs.count - 3) more in Longhaul")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func rowLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 16)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).foregroundStyle(.primary)
        }
    }

    private func action(_ title: String, symbol: String, shortcut: String? = nil,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                rowLabel(title, symbol: symbol)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hoveredAction == title ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering in
            if hovering { hoveredAction = title }
            else if hoveredAction == title { hoveredAction = nil }
        }
    }
}
