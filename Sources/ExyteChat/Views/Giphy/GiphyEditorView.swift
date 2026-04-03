import SwiftUI

struct GiphyEditorView: View {
    @Environment(\.dismiss) private var dismiss
    private let giphyConfig: GiphyConfiguration
    
    init(giphyConfig: GiphyConfiguration) {
        self.giphyConfig = giphyConfig
    }
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Giphy picker unavailable")
                .font(.headline)

            Text("This ExyteChat build no longer bundles the Giphy SDK.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if let giphyKey = giphyConfig.giphyKey, !giphyKey.isEmpty {
                Text("Existing Giphy media IDs can still render in messages.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            Button("Close") {
                dismiss()
            }
        }
        .padding(24)
        .presentationDetents([.fraction(giphyConfig.presentationDetents)])
    }
}
