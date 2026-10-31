import SwiftUI

struct SettingsView: View {
    @AppStorage(Preferences.barsKey) private var bars: BarsWhileReading = .hide

    var body: some View {
        Form {
            Section {
                Picker("Menu bar and Dock", selection: $bars) {
                    ForEach(BarsWhileReading.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text(bars.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
