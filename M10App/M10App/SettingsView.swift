import SwiftUI

/// Settings sheet: cache usage + maintenance, album rules reference.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let usage = appState.cacheUsage {
                    Section("Cache") {
                        LabeledRow("Photos known", "\(usage.entries)")
                        LabeledRow("Full downloads", "\(usage.fulls)")
                        LabeledRow("Thumbnails", "\(usage.thumbs)")
                        LabeledRow("On disk",
                                   ByteCountFormatter.string(fromByteCount: Int64(usage.bytes),
                                                             countStyle: .file))
                    }
                    Section {
                        Button(role: .destructive) {
                            Task { await appState.clearCache(keepMetadata: true) }
                        } label: {
                            Label("Clear media (keep metadata)", systemImage: "trash")
                        }
                        Button(role: .destructive) {
                            Task { await appState.clearCache(keepMetadata: false) }
                        } label: {
                            Label("Clear everything", systemImage: "trash.fill")
                        }
                    }
                }

                Section("Album rules") {
                    LabeledRow("Starred", "Favorite + “\(PhotoKitService.starredAlbum)”")
                    LabeledRow("DNG", "“\(PhotoKitService.rawAlbum)”")
                    LabeledRow("Plain JPEG", "library only")
                }

                Section("About") {
                    LabeledRow("Camera", appState.cameraName.isEmpty ? "—" : appState.cameraName)
                    LabeledRow("Firmware", appState.firmwareVersion)
                    LabeledRow("Serial", appState.serialNumber)
                    LabeledRow("Protocol", "PTP/IP + MTP")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await appState.refreshCacheUsage() }
        }
    }

    private struct LabeledRow: View {
        let label: String, value: String
        init(_ label: String, _ value: String) {
            self.label = label; self.value = value
        }
        var body: some View {
            HStack {
                Text(label)
                Spacer()
                Text(value).foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
    }
}
