import SwiftUI

struct GiphyMediaView: View {
    let id: String
    @Binding var aspectRatio: CGFloat

    var body: some View {
        CachedAsyncImage(
            url: URL(string: "https://media.giphy.com/media/\(id)/giphy.gif"),
            cacheKey: "giphy-\(id)"
        ) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.06))
        }
        .task {
            aspectRatio = 1
        }
        .clipped()
    }
}
