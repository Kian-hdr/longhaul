import SwiftUI
import LonghaulCore
import LonghaulBridge

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedJob: TrackedJob?
    @State private var selectedJobID: String?
    @State private var confirmSleep = false
    var body: some View {
        NavigationSplitView {
            List(selection: Binding<AppDestination?>(
                get: { model.selection },
                set: { if let destination = $0 { model.navigate(to: destination) } }
            )) {
                Section("Work") {
                    ForEach(AppDestination.work) { destination in
                        Label(destination.title, systemImage: destination.symbol).tag(destination)
                    }
                }
                Section("Settings") {
                    ForEach(AppDestination.settings) { destination in
                        Label(destination.title, systemImage: destination.symbol).tag(destination)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            GeometryReader { _ in
                VStack(spacing: 0) {
                    statusHeader
                    if let seconds = model.sleepCountdown {
                        HStack {
                            Label("Sleeping in \(seconds) seconds", systemImage: "moon.zzz")
                            Spacer()
                            Button("Cancel") { model.cancelSleep() }
                        }.font(.callout).padding(.horizontal, 20).padding(.bottom, 12)
                    }
                    Divider()
                    Group {
                        if !model.onboardingComplete && model.selection == .activity {
                            ScrollView { OnboardingView() }
                        } else {
                            switch model.selection {
                            case .activity: activity
                            case .history: history
                            case .recovery: recovery
                            default: SettingsContent(destination: model.selection)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .safeAreaInset(edge: .bottom) {
                    if let error = model.error {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            Text(error).font(.callout).textSelection(.enabled)
                            Spacer()
                            Button("Dismiss", systemImage: "xmark") { model.error = nil }.labelStyle(.iconOnly)
                        }.padding(12).background(.bar)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(.background)
        .toolbar {
            ToolbarItemGroup {
                Button(model.settings.enabled ? "Pause" : "Resume", systemImage: model.settings.enabled ? "pause" : "play") { model.toggleAutomation() }
                    .labelStyle(.iconOnly).help("Pause or resume automatic protection")
                Menu("Keep Awake", systemImage: "timer") {
                    Button("30 minutes") { model.keepAwake(minutes: 30) }
                    Button("1 hour") { model.keepAwake(minutes: 60) }
                    Button("4 hours") { model.keepAwake(minutes: 240) }
                    Divider(); Button("End manual session") { model.endManual() }
                    Divider(); Button("Sleep This Mac…") { confirmSleep = true }
                }.labelStyle(.iconOnly)
                Button("Export Diagnostics", systemImage: "square.and.arrow.up") { model.exportHistory() }
                    .labelStyle(.iconOnly)
            }
        }
        .task(id: model.selection) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            model.recordWindowGeometry()
        }
        .sheet(item: $selectedJob) { selected in JobDetail(job: model.jobs.first(where: { $0.id == selected.id }) ?? selected).environment(model).frame(width: 500).padding(24) }
        .alert("Put this Mac to sleep?", isPresented: $confirmSleep) {
            Button("Cancel", role: .cancel) { }
            Button("Sleep Now") { model.sleepNow() }
        } message: { Text("Active local work will pause until the Mac wakes. Longhaul will release its own protection.") }
    }
    private var statusHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: model.symbol).font(.system(size: 32)).foregroundStyle(model.decision?.stage == .critical ? Color.orange : Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.selection.title).font(.title2.weight(.semibold)).lineLimit(1)
                Text(model.isPreview ? "Preview · " + model.title : model.title)
                    .foregroundStyle(.secondary).font(.callout).lineLimit(2).help(model.title)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Label(model.batteryText, systemImage: model.power.onAC ? "battery.100percent.bolt" : "battery.50percent").font(.headline)
                Text(model.sourceText).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(height: 100)
    }
    private var activity: some View {
        List(selection: $selectedJobID) {
            VStack(alignment: .leading, spacing: 8) {
                Label(model.lidProtection.title, systemImage: "laptopcomputer")
                    .font(.headline)
                Text(model.lidProtection.detail)
                    .font(.callout).foregroundStyle(.secondary)
                if model.codexReportingUnconfirmed {
                    Label("No active Codex job reported", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                    Button("Check Codex Integration") { model.navigate(to: .integrations) }
                }
                if let notice = model.monitoringNotice {
                    HStack(alignment: .top) {
                        Text(notice.message + " Check your task’s progress.")
                            .font(.callout).textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button("Dismiss monitoring notice", systemImage: "xmark") { model.dismissedMonitoringID = notice.id }
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            if model.jobs.isEmpty {
                ContentUnavailableView {
                    Label("No work is being protected", systemImage: "moon.zzz")
                } description: { Text("Enable an integration in Settings, or protect a command with Longhaul. Opening an app alone does not start protection.") }
                actions: {
                    Button("Set Up Integrations") {
                        model.navigate(to: .integrations)
                    }
                }
            } else {
                ForEach(model.jobs) { job in
                    Button { selectedJob = job } label: { JobRow(job: job) }.buttonStyle(.plain)
                        .accessibilityLabel("\(job.event.title), \(job.event.source), \(job.stale ? "status unknown" : job.event.phase.label)")
                        .tag(job.id)
                }
            }
        }.listStyle(.inset)
        .onKeyPress(.return) {
            guard let job = model.jobs.first(where: { $0.id == selectedJobID }) else { return .ignored }
            selectedJob = job
            return .handled
        }
    }
    private var history: some View {
        Group {
            if model.history.isEmpty { ContentUnavailableView("No events yet", systemImage: "clock", description: Text("Protection and recovery events appear here.")) }
            else {
                List(model.history) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Text(entry.date, format: .dateTime.hour().minute().second()).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.message).textSelection(.enabled)
                            Text(entry.category).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
    }
    private var recovery: some View {
        Group {
            if model.recovery.isEmpty {
                ContentUnavailableView("No confirmed checkpoints", systemImage: "externaldrive.badge.checkmark", description: Text("Compatible jobs can save recovery files before battery power is low. A checkpoint is listed only after an acknowledgement and file check."))
            } else {
                List(Array(model.recovery.enumerated()), id: \.offset) { _, receipt in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(receipt.source, systemImage: "doc.badge.clock").font(.headline)
                        Text(receipt.summary).textSelection(.enabled)
                        Text(receipt.success ? "Files acknowledged · application restore not verified" : "Saved files are currently unavailable")
                            .font(.caption).foregroundStyle(receipt.success ? Color.secondary : Color.orange)
                        ForEach(receipt.savedPaths, id: \.self) { path in
                            Button(URL(fileURLWithPath: path).lastPathComponent) { model.reveal(path) }.buttonStyle(.link).disabled(!receipt.success)
                        }
                    }.padding(.vertical, 8)
                }
            }
        }
    }
}

struct JobRow: View {
    let job: TrackedJob
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.event.phase == .failed ? "xmark.circle" : job.event.phase == .cancelled ? "minus.circle" : job.event.phase == .completed ? "checkmark.circle" : job.stale ? "exclamationmark.circle" : "bolt.circle")
                .font(.title2).foregroundStyle(job.stale ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.event.title).font(.headline).lineLimit(2)
                Text("\(job.event.source) · \(job.stale ? "Status unknown" : job.event.phase.label)").font(.callout).foregroundStyle(.secondary)
                if let progress = job.event.progress { ProgressView(value: progress).frame(maxWidth: 280) }
            }
            Spacer()
            Text(job.checkpoint == .unsupported ? "No recovery integration" : "Checkpoint: \(job.checkpoint.label)")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 8).contentShape(Rectangle())
    }
}

struct JobDetail: View {
    let job: TrackedJob
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(job.event.title).font(.title2.weight(.semibold))
            LabeledContent("Integration", value: job.event.source)
            LabeledContent("Status", value: job.stale ? "Unknown; protection released" : job.event.phase.label)
            LabeledContent("Last report", value: "\(Int(max(0, model.now - job.lastSeen))) seconds ago")
            LabeledContent("Recovery", value: job.checkpoint.label)
            if job.event.checkpointCapable {
                Text("Longhaul asks the application to save. An acknowledgement is not proof that the application can restore an interrupted operation.").font(.callout).foregroundStyle(.secondary)
                Button("Request Checkpoint") { Task { await model.requestCheckpoint(job) } }.disabled(job.event.phase.isTerminal || job.stale || job.checkpoint == .requested)
            }
            if let output = job.event.outputPath { Button("Show Output in Finder") { model.reveal(output) } }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
    }
}
