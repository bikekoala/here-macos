import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe.americas.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(.tint)

            Text("IP Guide")
                .font(.title2)
                .fontWeight(.semibold)

            Text(versionString)
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(String(localized: "Data provided by ip.guide"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Link(String(localized: "Visit ip.guide"), destination: URL(string: "https://ip.guide")!)
                .font(.caption)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}
