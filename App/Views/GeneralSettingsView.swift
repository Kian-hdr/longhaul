import SwiftUI
import ServiceManagement
import LonghaulCore

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Controls") {
                Picker("Show Longhaul in", selection: Binding(get: { model.selectedControlSurface }, set: { model.setControlSurface($0) })) {
                    ForEach(ControlSurface.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Text(model.controlSurfaceDescription).font(.callout).foregroundStyle(.secondary)
                if model.showMenuBarExtra {
                    Button("Open Menu Bar Controls") { model.openMenuBarControls() }
                }
                if model.selectedControlSurface == .nodebay, model.companion.nodebayInstalled,
                   !model.nodebayPaired || !model.companion.serviceEnabled {
                    Button("Connect Nodebay") { model.connectNodebay() }.disabled(!model.canConfigure)
                }
            }
            Section("Automatic protection") {
                Toggle("Protect supported jobs", isOn: $model.settings.enabled).onChange(of: model.settings.enabled) { model.saveSettings() }
                LabeledContent("Start at login", value: model.loginStatus)
                HStack {
                    Button(model.loginStatus == "On" ? "Turn Off Login Launch" : "Start at Login") { model.setLogin(model.loginStatus != "On") }.disabled(!model.canConfigure)
                    if model.loginStatus == "Approval needed" { Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() } }
                }
            }
            ClosedLidSettingsSection(
                enabled: $model.closedLidEnabled,
                batteryPolicy: $model.lidBatteryPolicy,
                canConfigure: model.canConfigure,
                detail: model.lidProtection.detail,
                saveEnabled: model.saveClosedLidSetting,
                saveBatteryPolicy: model.saveLidBatteryPolicy
            )
            Section("After work finishes") {
                Toggle("Sleep automatically after completion", isOn: $model.settings.completionSleep).onChange(of: model.settings.completionSleep) { model.saveSettings() }
                Text("Longhaul releases its own protection after 2 minutes. Automatic sleep also waits for 5 minutes without input and checks other apps' sleep assertions.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Important notifications") {
                LabeledContent("macOS permission", value: model.canConfigure ? model.notificationAuthorization : "Disabled in verification mode")
                if !model.notificationDelivery.isEmpty { Text(model.notificationDelivery).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    if !model.notificationsEnabled {
                        Button(model.notificationRequestInProgress ? "Waiting for macOS…" : "Enable Notifications") { model.enableNotifications() }
                            .disabled(!model.canConfigure || model.notificationRequestInProgress)
                    }
                    Button("Open System Settings") { model.openSystemSettings() }.disabled(!model.canConfigure)
                }
                HStack {
                    Button("Check Again") { Task { await model.refreshNotificationStatus() } }.disabled(!model.canConfigure)
                    Button("Send Test") { model.testNotification() }.disabled(!model.canConfigure || !model.notificationsEnabled)
                }
                Text("Change permission in System Settings > Notifications > Longhaul. Focus and macOS delivery settings can silence an allowed notification.").font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
