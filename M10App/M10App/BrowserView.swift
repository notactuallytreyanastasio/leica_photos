import SwiftUI
import M10Kit

/// The photo browser: newest-first grid, lazy metadata + thumbnails.
struct BrowserView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 4)],
                      spacing: 4) {
                ForEach(appState.visiblePhotos) { item in
                    Cell(item: item)
                        .task {
                            await appState.loadInfos(for: [item])
                            _ = await appState.thumbnail(for: item)
                        }
                }
            }
            .padding(4)
        }
        .navigationTitle(appState.cameraName)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text("\(appState.photos.count) photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.disconnect()
                } label: {
                    Image(systemName: "wifi.slash")
                }
            }
        }
    }

    private struct Cell: View {
        @EnvironmentObject var appState: AppState
        let item: PhotoItem

        var body: some View {
            Group {
                if let thumb = item.thumb, let ui = UIImage(data: thumb) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                } else if let info = item.info {
                    // metadata known, thumbnail in flight
                    ZStack {
                        Rectangle().fill(.quaternary)
                        VStack(spacing: 4) {
                            Text(info.format.displayName)
                                .font(.caption2)
                            Text(String(info.size / 1_000_000) + "MB")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 110, height: 82)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
