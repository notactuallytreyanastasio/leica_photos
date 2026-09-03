import SwiftUI
import M10Kit

/// Full photo view: EXIF line, metadata, download with progress, star
/// status, and save-to-Photos (Favorite + albums) once downloaded.
struct PhotoDetailView: View {
    @EnvironmentObject var appState: AppState
    let handle: UInt32

    @State private var previewData: Data?
    @State private var exif: ExifInfo?

    private var item: PhotoItem? {
        appState.photos.first { $0.handle == handle }
    }

    private var info: ObjectInfo? { item?.info }

    var body: some View {
        Group {
            if let item {
                content(item: item)
            } else {
                Text("Photo not found").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(info?.filename ?? "Photo")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let item { await appState.loadInfos(for: [item]) }
            await loadPreview()
        }
    }

    private func loadPreview() async {
        guard let data = await appState.photoData(for: handle) else { return }
        previewData = data
        exif = ExifInfo.parse(data)
    }

    @ViewBuilder
    private func content(item: PhotoItem) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                preview(item: item)

                if let exif, let line = exif.summaryLine {
                    HStack(spacing: 4) {
                        Image(systemName: "camera.metering.matrix")
                            .font(.caption)
                        Text(line)
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 8))
                    if let lens = exif.lensModel {
                        Text(lens)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

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
            if let data = previewData ?? item.thumb,
               let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottom) {
                        if appState.fullPhotos.contains(handle),
                           previewData != nil,
                           info?.format == .tiffDNG {
                            Text("DNG — full quality in cache")
                                .font(.caption2)
                                .padding(4)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .padding(4)
                        }
                    }
            } else if let thumb = item.thumb, let ui = UIImage(data: thumb) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
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
            LabeledRow("Size",
                       ByteCountFormatter.string(fromByteCount: Int64(info.size),
                                                 countStyle: .file))
            if info.pixels.w > 0 {
                LabeledRow("Resolution", "\(info.pixels.w) × \(info.pixels.h)")
            }
            LabeledRow("Captured", info.captured)
            LabeledRow("Handle", String(format: "%08X", info.handle))
            if let exif, let dt = exif.dateTimeOriginal {
                LabeledRow("Timestamp", dt)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func actions(item: PhotoItem) -> some View {
        let isDownloaded = appState.fullPhotos.contains(handle)
        let progress = appState.downloadProgress[handle]

        VStack(spacing: 12) {
            if let progress {
                ProgressView(value: progress) {
                    Text("Downloading… \(Int(progress * 100))%")
                }
            } else if !isDownloaded {
                Button {
                    Task {
                        await appState.downloadPhoto(handle)
                        await loadPreview()
                    }
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

            if let rating = appState.ratings[handle], rating > 0 {
                Text("Starred on camera (xmp:Rating \(rating))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
