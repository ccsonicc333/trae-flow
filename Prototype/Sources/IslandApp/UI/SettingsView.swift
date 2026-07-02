import SwiftUI

struct SettingsView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Island")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("A native notch companion for Trae.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Live State")
                    .font(.headline)
                Text("Sessions: \(appModel.snapshot.sessions.count)")
            }
            Spacer()
        }
        .padding(24)
    }
}
