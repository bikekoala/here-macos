import SwiftUI

struct ModulesSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                ForEach(settings.popoverModuleOrder) { module in
                    moduleRow(for: module, in: settings.popoverModuleOrder)
                }
            } header: {
                Text(String(localized: "Popover module order"))
            } footer: {
                Text(String(localized: "Reorder cards shown below the IP header in the popover."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Latency probe")) {
                Toggle(String(localized: "Enable"), isOn: $settings.latencyEnabled)

                Picker(String(localized: "Target"), selection: $settings.latencyProbeTarget) {
                    ForEach(LatencyProbeTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
                .disabled(!settings.latencyEnabled)

                Picker(String(localized: "Interval"), selection: $settings.latencyInterval) {
                    ForEach(LatencyInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .disabled(!settings.latencyEnabled)

                Picker(String(localized: "Slots"), selection: $settings.latencySlotCount) {
                    Text(verbatim: "30").tag(30)
                    Text(verbatim: "45").tag(45)
                    Text(verbatim: "60").tag(60)
                }
                .disabled(!settings.latencyEnabled)
            }

            Section {
                Picker(String(localized: "Source"), selection: $settings.throughputEndpoint) {
                    ForEach(ThroughputEndpoint.allCases) { endpoint in
                        Text(endpoint.label).tag(endpoint)
                    }
                }

                if settings.throughputEndpoint == .custom {
                    LabeledContent {
                        TextField(
                            "https://example.com/100mb.bin",
                            text: $settings.throughputCustomURL
                        )
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)
                    } label: {
                        Text(String(localized: "URL"))
                    }
                }
            } header: {
                Text(String(localized: "Throughput"))
            } footer: {
                Text(throughputFooterText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func throughputFooterText() -> String {
        switch settings.throughputEndpoint {
        case .cachefly:
            return String(localized: "Downloads a 100 MB test file from Cachefly's CDN. Widest global reach; default.")
        case .cloudflare:
            return String(localized: "Downloads 100 MB from speed.cloudflare.com. Blocked on some networks that SNI-filter Cloudflare's speed test host.")
        case .custom:
            return String(localized: "Any HTTPS file works. Larger files (≥ 10 MB) give a more stable reading. Blank or invalid URLs fall back to Cachefly.")
        }
    }

    @ViewBuilder
    private func moduleRow(for module: PopoverModule, in order: [PopoverModule]) -> some View {
        @Bindable var settings = settings
        let index = order.firstIndex(of: module) ?? 0
        HStack(spacing: 10) {
            Image(systemName: module.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(module.label)
            Spacer()
            Button {
                move(module, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .pointerStyle(.link)
            .disabled(index == 0)
            .help(String(localized: "Move up"))

            Button {
                move(module, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .pointerStyle(.link)
            .disabled(index == order.count - 1)
            .help(String(localized: "Move down"))
        }
    }

    private func move(_ module: PopoverModule, by offset: Int) {
        var order = settings.popoverModuleOrder
        guard let current = order.firstIndex(of: module) else { return }
        let target = current + offset
        guard order.indices.contains(target) else { return }
        order.remove(at: current)
        order.insert(module, at: target)
        settings.popoverModuleOrder = order
    }
}
