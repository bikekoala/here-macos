import SwiftUI

struct NetworkCard: View {
    let model: IPDataModel

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Network"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                CopyableRow(label: String(localized: "CIDR"), value: model.network.cidr, monospaced: true, copyable: false)
                CopyableRow(label: String(localized: "ASN"), value: model.asnLabel, copyable: false)
                CopyableRow(label: String(localized: "Org"), value: model.network.autonomousSystem.organization, copyable: false)
                CopyableRow(label: String(localized: "RIR"), value: model.network.autonomousSystem.rir, copyable: false)
            }
        }
    }
}
