import SwiftUI
import Photos

/// Settings sheet: cache usage + maintenance, album rules reference.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var photoAccessLabel: String {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return "Full access"
        case .limited: return "Limited"
        case .denied, .restricted: return "Denied"
        case .notDetermined: return "Not requested"
        @unknown default: return "?"
        }
    }

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

                Section("Experimental") {
                    Toggle("Probe object properties on connect", isOn: $appState.experimentalPreread)
                    if let codes = appState.discoveredObjectProps {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Camera reports \(codes.count) object properties:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(codes.map { String(format: "%04X", $0) }.joined(separator: " "))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } else if appState.experimentalPreread {
                        Text("Probe runs once after the next connect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Photos access") {
                    HStack {
                        Text("Library access")
                        Spacer()
                        Text(photoAccessLabel)
                            .foregroundStyle(.secondary)
                    }
                    Button("Request access now") {
                        Task { _ = await PhotoKitService.requestAccess() }
                    }
                    Text("Needed to file photos into “Best of Leica” and “RAW Leica”. You can also pre-grant it here instead of at first save.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
