import AppKit
import Observation
import ServiceManagement
import UserNotifications
import LonghaulCore
import LonghaulBridge

@MainActor @Observable
final class AppModel {
    var jobs: [TrackedJob] = []
    var history: [HistoryEntry] = []
    var recovery: [CheckpointReceipt] = []
    var power = PowerSnapshot()
    var decision: PolicyDecision?
    var error: String?
    var sleepCountdown: Int?
    var settings: PolicySettings
    var onboardingComplete: Bool
    var selection: AppDestination = .activity
    var lastSettingsPage: AppDestination = .general
    var notificationsEnabled: Bool
    var notificationAuthorization = "Checking"
    var notificationDelivery = ""
    var notificationRequestInProgress = false
    @ObservationIgnored private var lastNotificationError: String?
    var loginStatus = "Off"
    var isPreview: Bool
    @ObservationIgnored private var previewCompletion = false
    var suppressInitialWindow = CommandLine.arguments.contains("--background")
    var codexActivityEnabled: Bool
    var codexActivityStatus = "Checking native Codex activity…"
    var closedLidEnabled: Bool
    var lidBatteryPolicy: LidBatteryPolicy
    let lidProtection = LidProtectionService()
    var isHolding = false
    var isTerminating = false
    var profiles: [CodexProfile] = []
    var integrationMessage: String?
    var setupInProgress = false
    var profileStatus: [String: IntegrationInstallationStatus] = [:]
    var dismissedMonitoringID: Int64?
    var commandStatus: IntegrationInstallationStatus?
    var blenderStatus: IntegrationInstallationStatus?
    var canConfigure: Bool { !isPreview && root == Mailbox.defaultRoot }
    var resolve: ResolveBridge
    var companion = CompanionBridge()
    var nodebayPaired = false
    private var savedControlSurface: ControlSurface?
    var showMenuBarExtra = true
    @ObservationIgnored private var menuBar: MenuBarController?
    @ObservationIgnored private var nextControlSurfaceCheck = Date.distantPast
    var companionAlerts: [CompanionAlert] = []
    @ObservationIgnored private var alertDeadlines: [String: Date] = [:]
    @ObservationIgnored private var appliedCompanionCommands: [String] = []
    let root: URL
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var engine = PolicyEngine()
    @ObservationIgnored private let powerService = PowerService()
    @ObservationIgnored private var io: RuntimeIO?
    @ObservationIgnored private var recoveryIO: RuntimeIO?
    @ObservationIgnored private var recoveryInProgress = false
    @ObservationIgnored private var nextRecoveryCheck = Date.distantPast
    @ObservationIgnored private var journal: Journal?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var checkpointOutcomes: [String: CheckpointRequestStatus] = [:]
    @ObservationIgnored private var pending: [String: (CheckpointRequest, Double)] = [:]
    @ObservationIgnored private var clock = ContinuousClock()
    @ObservationIgnored private var origin = ContinuousClock.now
    @ObservationIgnored private var manualID: String?
    @ObservationIgnored private var manualEnd: Double?
    @ObservationIgnored private var lastMode: ProtectionMode?
    @ObservationIgnored private var lastBattery: BatteryStage = .normal
    @ObservationIgnored private var countdownEnd: Double?
    @ObservationIgnored private var emergencyAttempted = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var tickInProgress = false
    @ObservationIgnored private var lastTickSeen: Double?
    @ObservationIgnored private let integrationSetup = IntegrationSetup()

    init() {
        let preview = CommandLine.arguments.contains("--preview")
        isPreview = preview
        if let index = CommandLine.arguments.firstIndex(of: "--data-directory"), index + 1 < CommandLine.arguments.count {
            root = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        } else if preview { root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Longhaul/Preview") }
        else { root = Mailbox.defaultRoot }
        resolve = ResolveBridge(root: root, resources: Bundle.main.resourceURL?.appendingPathComponent("integrations"))
        let isolated = preview || CommandLine.arguments.contains("--data-directory")
        preferences = isolated ? UserDefaults(suiteName: "space.exlumina.longhaul.test." + Mailbox.key(root.path))! : .standard
        settings = (preferences.data(forKey: "policy").flatMap { try? JSONDecoder().decode(PolicySettings.self, from: $0) }) ?? .init()
        codexActivityEnabled = preferences.object(forKey: "codexActivityEnabled") as? Bool ?? true
        closedLidEnabled = preferences.bool(forKey: "closedLidEnabled")
        let savedLidBatteryPolicy = preferences.data(forKey: "closedLidBatteryPolicy")
            .flatMap { try? JSONDecoder().decode(LidBatteryPolicy.self, from: $0) }
        lidBatteryPolicy = savedLidBatteryPolicy.flatMap { $0.isValid ? $0 : nil } ?? .init()
        onboardingComplete = preferences.bool(forKey: "onboardingComplete")
        if let saved = AppDestination(rawValue: preferences.string(forKey: "settingsSection") ?? ""), saved.isSettings {
            lastSettingsPage = saved
        }
        notificationsEnabled = preferences.bool(forKey: "notificationsEnabled")
        settings.normalize()
        nodebayPaired = preferences.bool(forKey: "nodebayPaired")
        savedControlSurface = preferences.string(forKey: "controlSurface").flatMap(ControlSurface.init(rawValue:))
        refreshControlSurface(discover: true)
        do {
            io = try RuntimeIO(root: root)
            recoveryIO = try RuntimeIO(root: root)
            journal = Journal(url: root.appendingPathComponent("history.sqlite"))
        } catch { self.error = "Longhaul could not create its private data folder. Protection is disabled."; settings.enabled = false }
        loginStatus = Self.loginDescription()
        powerService.onChange = { [weak self] in Task { @MainActor in await self?.tick() } }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lidProtection.revoke(reason: "Session resumed; checking protection again."); self?.engine.reconcileAfterWake(); self?.record("Power", "Session resumed; reconciling job state") }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lidProtection.revoke(reason: "macOS is sleeping."); self?.record("Power", "macOS reported system sleep") }
        })
        if isPreview { seedPreview() }
        if !isPreview { resolve.setEnabled(preferences.bool(forKey: "resolveEnabled")) }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        record("Lifecycle", isPreview ? "Preview opened; physical power actions disabled" : "Longhaul started")
        Task { recovery = (try? await io?.recovery()) ?? [] }
        Task { await refreshIntegrationStatus() }
        if canConfigure {
            Task { await refreshNotificationStatus() }
            if savedControlSurface == nil, preferences.object(forKey: "nodebayPaired") == nil, companion.nodebayInstalled {
                connectNodebay()
            }
        }
    }
    var now: Double { let d = origin.duration(to: clock.now).components; return Double(d.seconds) + Double(d.attoseconds) / 1e18 }
    var title: String { decision?.reason ?? "Starting Longhaul" }
    var symbol: String { switch decision?.mode { case .protecting, .saving: "bolt.shield.fill"; case .limited: "exclamationmark.shield"; case .paused: "pause.circle"; default: "moon.zzz" } }
    var activeCount: Int { decision?.protectedIDs.count ?? 0 }
    var codexReportingUnconfirmed: Bool {
        !isPreview && !profiles.isEmpty && !jobs.contains {
            ($0.event.source.hasPrefix("Codex (") || $0.event.source.hasPrefix("Codex activity (")) && !$0.event.phase.isTerminal && !$0.stale
        }
    }
    func codexReportingDescription(_ profile: CodexProfile) -> String {
        let sources = ["Codex (\(profile.name))", "Codex activity (\(profile.name))"]
        let reported = jobs.filter { sources.contains($0.event.source) && !$0.event.phase.isTerminal }
        if reported.contains(where: { !$0.stale && isHolding && decision?.protectedIDs.contains($0.id) == true }) {
            return "Live job reporting · idle-sleep protection active"
        }
        if reported.contains(where: { !$0.stale }) {
            return "Live job reporting · check Activity for protection status"
        }
        if !reported.isEmpty { return "Job contact lost · protection is unconfirmed" }
        return "No active job reported. If Codex is working, review /hooks in that profile before relying on automatic protection."
    }
    var monitoringNotice: HistoryEntry? {
        guard let latest = history.first(where: { $0.category == "Monitoring" }),
              latest.id != dismissedMonitoringID, latest.date.timeIntervalSinceNow > -86_400 else { return nil }
        return latest
    }
    var batteryText: String { power.percent.map { "\(Int($0.rounded()))%" } ?? "No battery reading" }
    var sourceText: String { power.onAC ? (power.discharging ? "Connected, discharging" : "Connected to power") : "Using battery" }
    func saveCodexActivitySetting() {
        preferences.set(codexActivityEnabled, forKey: "codexActivityEnabled")
        Task { await tick() }
    }
    private var nativeCodexHosts: [CodexNativeHost] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.bundleIdentifier == "com.openai.codex", let bundle = app.bundleURL else { return nil }
            let birth = ProcessIdentity.birth(app.processIdentifier)
            guard birth != 0 else { return nil }
            return CodexNativeHost(appPID: app.processIdentifier, appBirth: birth,
                                   codexExecutableURL: bundle.appendingPathComponent("Contents/Resources/codex"))
        }
    }
    func saveClosedLidSetting() {
        preferences.set(closedLidEnabled, forKey: "closedLidEnabled")
        if !closedLidEnabled { lidProtection.revoke(reason: "Closed-lid protection disabled.") }
        else { lidProtection.rearm() }
        Task { await tick() }
    }
    func saveLidBatteryPolicy() {
        guard lidBatteryPolicy.isValid else { return }
        if let data = try? JSONEncoder().encode(lidBatteryPolicy) {
            preferences.set(data, forKey: "closedLidBatteryPolicy")
        }
        // A deliberate setting change may retry a cleanly released episode.
        lidProtection.rearm()
        Task { await tick() }
    }
    func saveSettings() {
        if !settings.enabled { lidProtection.revoke(reason: "Automation paused.") }
        settings.normalize()
        if let data = try? JSONEncoder().encode(settings) { preferences.set(data, forKey: "policy") }
        Task { await tick() }
    }
    func toggleAutomation() { settings.enabled.toggle(); saveSettings(); record("Policy", settings.enabled ? "Automation resumed" : "Automation paused") }
    func finishOnboarding() { onboardingComplete = true; preferences.set(true, forKey: "onboardingComplete") }
    func navigate(to destination: AppDestination) {
        selection = destination
        if destination.isSettings {
            lastSettingsPage = destination
            preferences.set(destination.rawValue, forKey: "settingsSection")
        }
    }
    func showSettings() { navigate(to: lastSettingsPage) }
    func startMenuBar() {
        guard menuBar == nil, !isTerminating else { return }
        menuBar = MenuBarController(model: self)
        refreshControlSurface()
    }
    func openMenuBarControls() {
        refreshControlSurface()
        menuBar?.togglePopover()
    }
    var selectedControlSurface: ControlSurface {
        .preferred(saved: savedControlSurface, nodebayInstalled: companion.nodebayInstalled)
    }
    var controlSurfaceDescription: String {
        if selectedControlSurface == .menuBar { return "Controls appear in the menu bar. Nodebay can still report jobs and show notices." }
        if !companion.nodebayInstalled { return "Nodebay isn’t installed. Longhaul is using the menu bar." }
        if !nodebayPaired || !companion.serviceEnabled { return "Connect Nodebay to use it here. Longhaul stays in the menu bar until connected." }
        if !companion.linked { return "Nodebay is unavailable. Longhaul is temporarily using the menu bar." }
        if !companion.supportsControlSurface { return "Update Nodebay to switch controls. Longhaul is using the menu bar." }
        return "Controls appear in Nodebay. You can always open this window from Applications."
    }
    func setControlSurface(_ value: ControlSurface) {
        savedControlSurface = value
        preferences.set(value.rawValue, forKey: "controlSurface")
        refreshControlSurface(discover: true)
        if value == .nodebay, companion.nodebayInstalled, !nodebayPaired || !companion.serviceEnabled {
            connectNodebay()
        }
        record("Appearance", "Controls selected: \(value.title)")
        Task { await tick() }
    }
    private func refreshControlSurface(discover: Bool = false) {
        if discover {
            companion.nodebayInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "theboringteam.boringnotch")
                .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            companion.refreshStatus()
            nextControlSurfaceCheck = Date().addingTimeInterval(10)
        }
        showMenuBarExtra = selectedControlSurface.usesMenuBar(nodebayInstalled: companion.nodebayInstalled,
            paired: nodebayPaired, linked: companion.linked, routingSupported: companion.supportsControlSurface)
        menuBar?.update(visible: showMenuBarExtra, symbol: symbol, summary: title)
    }
    func recordWindowGeometry() {
        guard isPreview || root != Mailbox.defaultRoot else { return }
        let windows = NSApp.windows.filter { $0.title == "Longhaul" && $0.isVisible }
        guard let frame = windows.first?.frame else { return }
        record("UI verification", "\(selection.title); main windows \(windows.count); frame \(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))")
    }
    func setLogin(_ enabled: Bool) {
        guard canConfigure else { error = "Login registration is disabled in verification mode."; return }
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginStatus = Self.loginDescription() }
        catch { self.error = "Login setting was not changed: \(error.localizedDescription)" }
    }
    static func loginDescription() -> String {
        switch SMAppService.mainApp.status { case .enabled: "On"; case .requiresApproval: "Approval needed"; case .notRegistered: "Off"; default: "Unavailable" }
    }
    func enableNotifications() {
        guard canConfigure, !notificationRequestInProgress else { return }
        notificationRequestInProgress = true
        Task {
            defer { notificationRequestInProgress = false }
            let status = await refreshNotificationStatus()
            if status == .denied {
                showNotificationError("Notifications are not allowed. Enable Longhaul in System Settings > Notifications, then return here or choose Check Again. Protection continues without notifications.")
                return
            }
            guard status == .notDetermined else { return }
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                if !granted { showNotificationError("Notifications are not allowed. Enable Longhaul in System Settings > Notifications to receive battery and recovery alerts. Protection still works without notifications.") }
            }
            catch {
                let issue = error as NSError
                showNotificationError("macOS could not enable notifications. Check Longhaul in System Settings > Notifications. Protection continues, and connected Nodebay can still show important notices.")
                record("Notification", "Authorization failed: \(issue.domain) (\(issue.code)): \(issue.localizedDescription)")
            }
            await refreshNotificationStatus()
        }
    }
    @discardableResult
    func refreshNotificationStatus() async -> UNAuthorizationStatus? {
        guard canConfigure else { return nil }
        let status = await UNUserNotificationCenter.current().notificationSettings()
        let authorization: String
        switch status.authorizationStatus {
        case .notDetermined: authorization = "Permission not yet decided"
        case .denied: authorization = "Not allowed in macOS"
        case .authorized: authorization = "Allowed"
        case .provisional: authorization = "Quiet delivery only"
        @unknown default: authorization = "Unknown macOS permission state"
        }
        func label(_ setting: UNNotificationSetting) -> String {
            switch setting { case .enabled: "on"; case .disabled: "off"; case .notSupported: "unavailable"; @unknown default: "unknown" }
        }
        let delivery = "Alerts \(label(status.alertSetting)) · sounds \(label(status.soundSetting)) · Notification Center \(label(status.notificationCenterSetting))"
        if notificationAuthorization != authorization || notificationDelivery != delivery {
            record("Notification", "Permission: \(authorization) (\(status.authorizationStatus.rawValue)); \(delivery)")
        }
        notificationAuthorization = authorization
        notificationDelivery = delivery
        notificationsEnabled = [.authorized, .provisional].contains(status.authorizationStatus)
        preferences.set(notificationsEnabled, forKey: "notificationsEnabled")
        if notificationsEnabled {
            if error == lastNotificationError { error = nil }
            lastNotificationError = nil
        }
        return status.authorizationStatus
    }
    private func showNotificationError(_ message: String) {
        lastNotificationError = message
        error = message
    }
    func testNotification() {
        guard canConfigure else { return }
        systemNotify("Longhaul notification test", "Battery and recovery notices use this macOS notification channel when Nodebay is unavailable.")
    }
    func openSystemSettings() {
        guard canConfigure, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else { return }
        NSWorkspace.shared.open(url)
    }
    func installHooks(_ profile: CodexProfile) {
        guard canConfigure, !setupInProgress, let cli = Bundle.main.url(forResource: "longhaul", withExtension: nil, subdirectory: "bin") else { return }
        setupInProgress = true
        Task {
            defer { setupInProgress = false }
            do { integrationMessage = try await integrationSetup.installHooks(profile: profile.url, cli: cli, mailbox: root); record("Setup", "Codex hooks installed; trust review required"); await refreshIntegrationStatus() }
            catch { self.error = error.localizedDescription }
        }
    }
    func installBlender() {
        guard canConfigure, !setupInProgress, let resources = Bundle.main.resourceURL?.appendingPathComponent("integrations") else { return }
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "org.blenderfoundation.blender" }) else {
            error = "Save your work and quit Blender before installing its integration."; return
        }
        setupInProgress = true
        Task {
            defer { setupInProgress = false }
            do { integrationMessage = try await integrationSetup.installBlender(resources: resources, root: root); record("Setup", "Blender add-on installed and enabled"); await refreshIntegrationStatus() }
            catch { self.error = error.localizedDescription }
        }
    }
    func setResolve(_ enabled: Bool) {
        guard canConfigure else { return }
        preferences.set(enabled, forKey: "resolveEnabled"); resolve.setEnabled(enabled)
    }
    func installCommandTool() {
        guard canConfigure, let cli = Bundle.main.url(forResource: "longhaul", withExtension: nil, subdirectory: "bin") else { return }
        Task {
            do { integrationMessage = try await integrationSetup.installCommandTool(cli: cli); record("Setup", "Command tool installed"); await refreshIntegrationStatus() }
            catch { self.error = error.localizedDescription }
        }
    }
    func refreshIntegrationStatus() async {
        profiles = await integrationSetup.profiles()
        for profile in profiles {
            profileStatus[profile.id] = try? await integrationSetup.hookStatus(profile: profile.url)
        }
        commandStatus = try? await integrationSetup.commandToolStatus()
        blenderStatus = try? await integrationSetup.blenderStatus()
    }
    func removeHooks(_ profile: CodexProfile) {
        guard canConfigure, !setupInProgress else { return }
        setupInProgress = true
        Task {
            defer { setupInProgress = false }
            do { integrationMessage = try await integrationSetup.removeHooks(profile: profile.url); await refreshIntegrationStatus() }
            catch { self.error = error.localizedDescription }
        }
    }
    func removeCommandTool() {
        guard canConfigure, !setupInProgress else { return }
        setupInProgress = true
        Task {
            defer { setupInProgress = false }
            do { integrationMessage = try await integrationSetup.removeCommandTool(); await refreshIntegrationStatus() }
            catch { self.error = error.localizedDescription }
        }
    }
    func notify(_ title: String, _ body: String) {
        guard !isPreview else { return }
        if companion.linked && nodebayPaired {
            if companionAlerts.count >= 32, let oldest = companionAlerts.first {
                systemNotify(oldest.title, oldest.body)
                companionAlerts.removeFirst(); alertDeadlines.removeValue(forKey: oldest.id)
            }
            let alert = CompanionAlert(title: title, body: body)
            companionAlerts.append(alert)
            alertDeadlines[alert.id] = Date().addingTimeInterval(20)
        } else { systemNotify(title, body) }
    }
    private func systemNotify(_ title: String, _ body: String) {
        guard canConfigure else { return }
        if isTerminating { submitSystemNotification(title, body); return }
        Task {
            await refreshNotificationStatus()
            guard !isTerminating else { return }
            submitSystemNotification(title, body)
        }
    }
    private func submitSystemNotification(_ title: String, _ body: String) {
        guard notificationsEnabled else {
            record("Notification", "Alert could not be delivered because notifications are disabled: \(title)")
            return
        }
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { [weak self] error in
            if let issue = error as NSError? {
                Task { @MainActor in self?.record("Notification", "Delivery failed: \(issue.domain) (\(issue.code)): \(issue.localizedDescription)") }
            }
        }
    }
    func connectNodebay() {
        guard canConfigure else { return }
        do {
            try companion.register()
            nodebayPaired = true; preferences.set(true, forKey: "nodebayPaired")
            record("Companion", "Nodebay connection enabled")
        } catch { self.error = "Nodebay connection could not be enabled: \(error.localizedDescription)" }
        refreshControlSurface()
    }
    func disableCompanionService() {
        guard canConfigure else { return }
        do { try companion.unregister(); disconnectNodebay() }
        catch { self.error = "The local connection could not be removed: \(error.localizedDescription)" }
    }
    func disconnectNodebay() {
        guard canConfigure else { return }
        nodebayPaired = false; preferences.set(false, forKey: "nodebayPaired")
        for alert in companionAlerts { systemNotify(alert.title, alert.body) }
        companionAlerts.removeAll(); alertDeadlines.removeAll()
        record("Companion", "Nodebay disconnected; other protection continues")
        refreshControlSurface()
    }
    private func updateCompanion() async {
        guard !isPreview, !isTerminating, root == Mailbox.defaultRoot else { return }
        let active = jobs.filter { !$0.event.phase.isTerminal && !$0.stale }
        let stage: String = switch decision?.stage { case .warning: "warning"; case .prepare: "prepare"; case .critical: "critical"; default: "normal" }
        var snapshot = CompanionSnapshot(mode: decision?.mode.rawValue ?? "ready", reason: title, protecting: isHolding,
            enabled: settings.enabled, jobs: active.map { .init($0.event) }, batteryStage: stage,
            batteryPercent: power.percent, checkpointSummary: recovery.first?.summary, alerts: companionAlerts)
        snapshot.controlSurface = selectedControlSurface.rawValue
        let commands = await companion.update(snapshot, paired: nodebayPaired)
        guard !isTerminating else { return }
        defer { refreshControlSurface() }
        for command in commands {
            if appliedCompanionCommands.contains(command.requestID) { companion.acknowledge(command.requestID); continue }
            var applied = true
            switch command.op {
            case "connect": nodebayPaired = true; preferences.set(true, forKey: "nodebayPaired")
            case "disconnect": disconnectNodebay()
            case "pause" where nodebayPaired: if settings.enabled { toggleAutomation() }
            case "resume" where nodebayPaired: if !settings.enabled { toggleAutomation() }
            case "keepAwake" where nodebayPaired: if let m = command.minutes, [30,60,240].contains(m) { keepAwake(minutes: m) }
            case "job" where nodebayPaired:
                if let event = command.job, event.source == "Nodebay", event.isValid {
                    do { try await io?.emit(event) } catch { applied = false; self.error = "Nodebay job status could not be saved." }
                }
            case "ackAlert":
                companionAlerts.removeAll { $0.id == command.alertID }
                if let id = command.alertID { alertDeadlines.removeValue(forKey: id) }
            default: break
            }
            guard !isTerminating else { return }
            if applied {
                appliedCompanionCommands.append(command.requestID)
                appliedCompanionCommands = Array(appliedCompanionCommands.suffix(1024))
                companion.acknowledge(command.requestID)
            }
        }
        for alert in companionAlerts where Date() >= (alertDeadlines[alert.id] ?? .distantPast) {
            systemNotify(alert.title, alert.body)
            companionAlerts.removeAll { $0.id == alert.id }; alertDeadlines.removeValue(forKey: alert.id)
        }
    }
    func keepAwake(minutes: Int) {
        settings.enabled = true; saveSettings()
        let id = UUID().uuidString; manualID = id; manualEnd = now + Double(minutes * 60)
        _ = engine.receive(JobEvent(id: id, source: "Manual", title: "Keep awake for \(minutes) minutes", session: id), now: now)
        Task { await tick() }
    }
    func endManual() {
        guard let id = manualID else { return }
        if let job = engine.jobs["Manual:" + id] {
            var event = job.event; event.sequence += 1; event.phase = .completed; engine.receive(event, now: now)
        }
        manualID = nil; manualEnd = nil
    }
    func cancelSleep() { previewCompletion = false; countdownEnd = nil; sleepCountdown = nil; engine.cancelCompletionSleep(); record("Power", "Completion sleep cancelled") }
    func sleepNow() { cancelSleep(); performSleep() }
    private func performSleep() {
        guard !isPreview else { record("Preview", "Sleep request simulated"); return }
        lidProtection.revoke(reason: "Sleep requested.")
        if let message = powerService.requestSleep() { error = message; record("Error", message) }
        else { record("Power", "Sleep requested; awaiting macOS sleep event") }
        isHolding = powerService.isHolding
    }
    func requestCheckpoint(_ job: TrackedJob) async {
        guard job.event.checkpointCapable, !job.event.phase.isTerminal,
              !pending.values.contains(where: { $0.0.jobID == job.event.id && $0.0.source == job.event.source && $0.0.session == job.event.session }) else { return }
        let request = CheckpointRequest(jobID: job.event.id, source: job.event.source, session: job.event.session,
                                        reason: decision?.stage == .prepare ? "Low battery or thermal state" : "Routine recovery checkpoint",
                                        deadline: Date().addingTimeInterval(settings.checkpointDeadline))
        do {
            guard let io else { throw CocoaError(.fileWriteUnknown) }
            try await io.request(request)
            pending[request.id] = (request, now + settings.checkpointDeadline)
            guard !isTerminating, engine.jobs[job.id]?.event.session == job.event.session else { return }
            engine.checkpointRequested(job.id)
            record("Recovery", "Checkpoint requested for \(job.event.title)")
        } catch { self.error = "Checkpoint request could not be saved."; if engine.jobs[job.id]?.event.session == job.event.session { engine.checkpointResult(job.id, success: false, now: now) } }
    }
    func tick() async {
        guard !tickInProgress, !isTerminating else { return }; tickInProgress = true
        defer { tickInProgress = false; refreshControlSurface() }
        var t = now
        if Date() >= nextControlSurfaceCheck { refreshControlSurface(discover: true) }
        if let previous = lastTickSeen, t - previous > 15 {
            record("Monitoring", "No policy sample for \(Int(t - previous)) seconds. This gap alone does not identify sleep or useful task progress.")
        }
        lastTickSeen = t
        if !isPreview { power = powerService.snapshot() }
        if !isPreview { Task { await resolve.refresh() } }
        if let manualID, let manualEnd {
            if t >= manualEnd { endManual() }
            else if var e = engine.jobs["Manual:" + manualID]?.event { e.sequence += 1; engine.receive(e, now: t) }
        }
        if isPreview { refreshPreview(t) }
        if let batch = await io?.poll(codexProfiles: profiles.map(\.url),
                                     nativeHosts: canConfigure && codexActivityEnabled ? nativeCodexHosts : [],
                                     monitorCodex: canConfigure && codexActivityEnabled) {
            guard !isTerminating, !Task.isCancelled else { return }
            pending = Dictionary(uniqueKeysWithValues: batch.requests.filter { $0.deadline > Date() }.map { ($0.id, ($0, now + max(0, $0.deadline.timeIntervalSinceNow))) })
            for event in batch.events {
                if let pid = event.pid, kill(pid, 0) != 0 && errno == ESRCH && !event.phase.isTerminal { continue }
                if let pid = event.pid, let birth = event.processBirth, !ProcessIdentity.isSame(pid: pid, birth: birth), !event.phase.isTerminal { continue }
                let key = event.source + ":" + event.id
                let old = engine.jobs[key]?.event.phase
                if engine.receive(event, now: t), old != event.phase { record("Job", "\(event.title): \(event.phase.label)") }
            }
            for observation in batch.retiredObservations { engine.retireObservation(observation.key, session: observation.session) }
            for key in batch.removedIDs { engine.removeObservation(key) }
            for key in batch.expiredIDs { engine.expire(key) }
            if let status = batch.codexActivityStatus { codexActivityStatus = status }
            if let issue = batch.errors.first { error = issue }
        }
        Task { await reconcileRecovery() }
        guard !isTerminating, !Task.isCancelled else { return }
        // Mailbox I/O can suspend this actor. Never renew power protection from
        // the timestamp or battery sample taken before that suspension. Keep
        // received events' original observation time so old work still expires.
        t = now
        let lidEvaluationTime = LidQualificationIO.monotonicSeconds()
        if !isPreview { power = powerService.snapshot() }
        if let manualEnd, t >= manualEnd { endManual() }
        let d = engine.evaluate(now: t, power: power, settings: settings, userIdle: powerService.userIdle,
                                externalHold: settings.completionSleep && powerService.otherAppsHoldSleep(),
                                closedLidBatteryPolicy: closedLidEnabled ? lidBatteryPolicy : nil)
        decision = d; engine.prune(now: t)
        jobs = engine.jobs.values.sorted { ($0.event.phase.isTerminal ? 1 : 0, $0.firstSeen) < ($1.event.phase.isTerminal ? 1 : 0, $1.firstSeen) }
        if !isPreview {
            if let message = powerService.setHold(d.shouldHold) { error = message; record("Power", message) }
            isHolding = powerService.isHolding
            let safePower = power.supportsClosedLidWork(policy: lidBatteryPolicy)
            lidProtection.evaluate(workPresent: !d.protectedIDs.isEmpty || (d.graceRemaining ?? 0) > 0,
                                   eligible: canConfigure && closedLidEnabled && settings.enabled && d.shouldHold && isHolding && safePower,
                                   evaluatedAt: lidEvaluationTime,
                                   executable: Bundle.main.resourceURL?.appendingPathComponent("bin/longhaul"),
                                   batteryPolicy: lidBatteryPolicy)
        }
        if lastMode != d.mode { lastMode = d.mode; record("Policy", d.reason) }
        if lastBattery != d.stage {
            lastBattery = d.stage; record("Battery", d.stage.label)
            if d.stage > .normal { notify(d.stage.label, d.reason) }
        }
        for id in d.checkpointIDs { if let j = engine.jobs[id] { await requestCheckpoint(j) } }
        guard !isTerminating, !Task.isCancelled else { return }
        Task { await updateCompanion() }
        if d.emergencySleep && !emergencyAttempted {
            emergencyAttempted = true; cancelSleep(); performSleep()
        } else if !d.emergencySleep { emergencyAttempted = false }
        if isPreview && previewCompletion {
            sleepCountdown = 30
        } else if d.sleepEligible {
            if countdownEnd == nil { countdownEnd = t + 30; record("Power", "Completion sleep countdown started") }
            sleepCountdown = max(0, Int((countdownEnd ?? t) - t))
            if sleepCountdown == 0 { cancelSleep(); performSleep() }
        } else { countdownEnd = nil; sleepCountdown = nil }
    }
    private func reconcileRecovery() async {
        guard !isTerminating, !recoveryInProgress, Date() >= nextRecoveryCheck else { return }
        recoveryInProgress = true
        defer { recoveryInProgress = false; nextRecoveryCheck = Date().addingTimeInterval(5) }
        if let io = recoveryIO {
            do {
                let reconciled = try await io.reconcile(currentJobs: engine.jobs.values.map(\.event), now: Date())
                guard !isTerminating, !Task.isCancelled else { return }
                // Only the latest request for an exact incarnation controls its visible state.
                let grouped = Dictionary(grouping: reconciled.outcomes, by: \.identity)
                for outcomes in grouped.values {
                    guard let outcome = outcomes.max(by: { ($0.createdAt ?? $0.deadline, $0.requestID) < ($1.createdAt ?? $1.deadline, $1.requestID) }),
                          let current = engine.jobs[outcome.identity.source + ":" + outcome.identity.jobID],
                          outcome.applies(to: current.event), checkpointOutcomes[outcome.requestID] != outcome.status else { continue }
                    checkpointOutcomes[outcome.requestID] = outcome.status
                    if outcome.status == .pending { engine.checkpointRequested(current.id) }
                    else {
                        let onTime = outcome.status == .acknowledged && outcome.receiptTiming == .observedWithinDeadline
                        engine.checkpointResult(current.id, success: outcome.status == .acknowledged, now: now, late: !onTime)
                        switch outcome.status {
                        case .acknowledged:
                            record("Recovery", onTime ? "Checkpoint acknowledged; saved files exist. Restore not yet verified." : "Saved files acknowledged after the deadline; recovery retained with timing uncertainty.")
                        case .expired, .failed:
                            record("Recovery", "Checkpoint was not confirmed before its deadline")
                            notify("Checkpoint not confirmed", "Connect to power. Longhaul has not confirmed a new recovery save.")
                        default: break
                        }
                    }
                }
                recovery = try await io.recovery()
            } catch { self.error = "Recovery reconciliation failed; checkpoint confirmation is unavailable." }
        }
    }
    func record(_ category: String, _ message: String) {
        Task {
            do { try await journal?.append(category: category, message: message); history = try await journal?.recent() ?? [] }
            catch { self.error = "History could not be saved. Recovery evidence may be incomplete." }
        }
    }
    func exportHistory() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Longhaul-diagnostics.json"; panel.allowedContentTypes = [.json]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in do { try await self?.io?.export(self?.history ?? [], to: url) } catch { self?.error = "Diagnostics could not be exported." } }
        }
    }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func stop() {
        isTerminating = true; loop?.cancel()
        lidProtection.revoke(reason: "Longhaul is closing.")
        powerService.shutdown()
        for alert in companionAlerts { systemNotify(alert.title, alert.body) }
        companionAlerts.removeAll(); alertDeadlines.removeAll()
        resolve.stop(); companion.stop(); menuBar?.stop(); menuBar = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    private func seedPreview() {
        power = .init(percent: 74, onAC: true)
        if let index = CommandLine.arguments.firstIndex(of: "--scenario"), index + 1 < CommandLine.arguments.count {
            switch CommandLine.arguments[index + 1] {
            case "low-battery": power = .init(percent: 19, onAC: false, discharging: true, secondsRemaining: 1100)
            case "critical": power = .init(percent: 9, onAC: false, discharging: true, secondsRemaining: 540)
            case "completion": previewCompletion = true; return
            case "empty": return
            default: break
            }
        }
        engine.receive(JobEvent(id: "preview-codex", source: "Codex", title: "Building a native app", session: "preview", checkpointCapable: true), now: now)
        engine.receive(JobEvent(id: "preview-render", source: "Blender", title: "Rendering frames", session: "preview", progress: 0.64, checkpointCapable: true), now: now)
    }
    private func refreshPreview(_ t: Double) {
        for job in engine.jobs.values where !job.event.phase.isTerminal { var e = job.event; e.sequence += 1; engine.receive(e, now: t) }
    }
}
