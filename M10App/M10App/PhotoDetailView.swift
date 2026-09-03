import SwiftUI
import M10Kit

/// Full photo view: metadata, download with progress, star status,
/// and save-to-Photos (Favorite + album) once downloaded.
struct PhotoDetailView: View {
    @EnvironmentObject var appState: AppState
    let handle: UInt32

    private var item: PhotoItem? {
        appState.photos.first { $0.handle == handle }
    }

    private var info: ObjectInfo? { item?.info }

    var body: some View {
        Group {
            if let item {
                content(item: item)
            } else {
                Text("Photo not found")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(info?.filename ?? "Photo")
        .navigationBarTitleDisplayMode(.inline)
        .task { if let item { await appState.loadInfos(for: [item]) } }
    }

    @ViewBuilder
    private func content(item: PhotoItem) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                preview(item: item)

                if let info {
                    metadataCard(info: info)
                }

                actions(item: item)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func preview(item: PhotoItem) -> some View {
        let rating = appState.ratings[handle]
        ZStack(alignment: .topTrailing) {
            if let data = appState.downloaded[handle],
               let ui = UIImage(data: data) {
                // JPEGs render; DNGs won't via UIImage — fall through
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let thumb = item.thumb, let ui = UIImage(data: thumb) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottom) {
                        if appState.downloaded[handle] != nil {
                            Text("DNG — full quality downloaded")
                                .font(.caption2)
                                .padding(4)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .padding(4)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(height: 200)
                    .overlay {
                        if let fmt = item.info?.format.displayName {
                            Text(fmt).foregroundStyle(.secondary)
                        }
                    }
            }

            if let rating, rating > 0 {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .font(.title2)
                    .padding(8)
            }
        }
    }

    private func metadataCard(info: ObjectInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledRow("Format", info.format.displayName)
            LabeledRow("Size", ByteCountFormatter.string(fromByteCount: Int64(info.size), countStyle: .file))
            if info.pixels.w > 0 {
                LabeledRow("Resolution", "\(info.pixels.w) × \(info.pixels.h)")
            }
            LabeledRow("Captured", info.captured)
            LabeledRow("Handle", String(format: "%08X", info.handle))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func actions(item: PhotoItem) -> some View {
        let isDownloaded = appState.downloaded[handle] != nil
        let progress = appState.downloadProgress[handle]

        VStack(spacing: 12) {
            if let progress {
                ProgressView(value: progress) {
                    Text("Downloading… \(Int(progress * 100))%")
                }
            } else if !isDownloaded {
                Button {
                    Task { await appState.downloadPhoto(handle) }
                } label: {
                    Label("Download from camera", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(item.info == nil)
            }

            if isDownloaded {
                if appState.savedToPhotos.contains(handle) {
                    let albums = appState.albumNames(for: handle)
                    Label(
                        albums.isEmpty
                            ? "Saved to Photos"
                            : "Saved to Photos — \(albums.joined(separator: " • "))",
                        systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button {
                        Task { await appState.saveToPhotos(handle) }
                    } label: {
                        let favorite = (appState.ratings[handle] ?? 0) > 0
                        Label(
                            favorite ? "Save to Photos (★ Favorite)" : "Save to Photos",
                            systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.top)
    }

    private struct LabeledRow: View {
        let label: String, value: String
        init(_ label: String, _ value: String) {
            self.label = label; self.value = value
        }
        var body: some View {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).textSelection(.enabled)
            }
            .font(.subheadline)
        }
    }
}
