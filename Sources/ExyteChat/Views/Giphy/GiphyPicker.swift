import SwiftUI

public struct GiphyPicker: View {
    private let giphyConfig: GiphyConfiguration

    init(giphyConfig: GiphyConfiguration) {
        self.giphyConfig = giphyConfig
    }

    public var body: some View {
        GiphyEditorView(giphyConfig: giphyConfig)
    }
}
