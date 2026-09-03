import SwiftUI
import M10Kit

/// The photo browser: newest-first grid, lazy metadata + thumbnails.
/// Tap a photo for detail (download / star status / save to Photos).
struct BrowserView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 4)],
                      spacing: 4) {
                ForEach(appState.visiblePhotos) { item in
                    NavigationLink(value: item.handle) {
                        Cell(item: item)
                    }
                    .buttonStyle(.plain)
                    .task {
                        await appState.loadInfos(for: [item])
                        _ = await appState.thumbnail(for: item)
                    }
                }
            }
            .padding(4)
        }
        .navigationDestination(for: UInt32.self) { handle in
            PhotoDetailView(handle: handle)
        }
        .navigationTitle(appState.cameraName)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text("\(appState.photos.count) photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    appState.starredOnly.toggle()
                } label: {
                    Image(systemName: appState.starredOnly ? "star.fill" : "star")
                }
                .accessibilityLabel("Starred only")

                Button {
                    Task { await appState.saveStarredDownloaded() }
                } label: {
                    Image(systemName: "square.and.arrow.down.on.square")
                }
                .disabled(appState.starredImportRunning)
                .accessibilityLabel("Save starred downloads to Photos")

                Button {
                    appState.disconnect()
                } label: {
                    Image(systemName: "wifi.slash")
                }
                .accessibilityLabel("Disconnect")
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = appState.starredImportMessage {
                Text(msg)
                    .font(.footnote)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 8)
            }
        }
    }

    private struct Cell: View {
        @EnvironmentObject var appState: AppState
        let item: PhotoItem

        private var isStarred: Bool {
            (appState.ratings[item.handle] ?? 0) > 0
        }

        var body: some View {
            Group {
                if let thumb = item.thumb, let ui = UIImage(data: thumb) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                } else if let info = item.info {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        VStack(spacing: 4) {
                            Text(info.format.displayName)
                                .font(.caption2)
                            Text("\(info.size / 1_000_000)MB")
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
            .overlay(alignment: .bottomTrailing) {
                if isStarred {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .padding(3)
                        .shadow(radius: 1)
                }
                if appState.savedToPhotos.contains(item.handle) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(3)
                }
            }
        }
    }
}
