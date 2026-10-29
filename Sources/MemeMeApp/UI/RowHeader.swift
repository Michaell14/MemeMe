import SwiftUI

/// A web row's name over its tiles, with its source's attribution on the right ("from Imgflip", "Powered by GIPHY").
struct RowHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.softText)
            Spacer(minLength: 0)
            trailing
        }
        .frame(height: 16)
    }
}
