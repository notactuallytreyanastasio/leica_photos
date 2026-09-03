import SwiftUI
import M10Kit

/// The photo browser: camera header, filter chips, newest-first grid
/// grouped by capture date. Tap a photo for detail.
struct BrowserView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                cameraHeader
                filterBar
                photoSections
                if appState.metadataLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading photo info \(appState.metadataLoadedCount)/\(appState.photos.count)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 4)
        }
        .searchable(text: $appState.searchText, prompt: "Search filename")
        .task { await appState.loadNextMetadataPage() }
        .navigationTitle(appState.cameraName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await appState.saveStarredDownloaded() }
                } label: {
                    Image(systemName: "square.and.arrow.down.on.square")
                }
                .disabled(appState.starredImportRunning)
                .accessibilityLabel("Save starred downloads to Photos")

                Button {
                    appState.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }

                Button {
                    appState.disconnect()
                } label: {
                    Image(systemName: "wifi.slash")
                }
                .accessibilityLabel("Disconnect")
            }
        }
        .sheet(isPresented: $appState.showSettings) {
            SettingsView()
                .environmentObject(appState)
                .presentationDetents([.medium])
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

    // MARK: - header

    private var cameraHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.aperture")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(appState.cameraName) · \(appState.photos.count) photos")
                    .font(.subheadline.weight(.semibold))
                Text("fw \(appState.firmwareVersion) · s/n …\(appState.serialNumber.suffix(4))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if appState.batteryPercent >= 0 {
                HStack(spacing: 3) {
                    Image(systemName: appState.batteryPercent > 30
                          ? "battery.100" : "battery.25")
                        .foregroundStyle(appState.batteryPercent > 30 ? .green : .red)
                    Text("\(appState.batteryPercent)%")
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - filters

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(AppState.Filter.allCases) { f in
                Button {
                    appState.filter = f
                } label: {
                    Text(f.rawValue)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            appState.filter == f
                                ? AnyShapeStyle(.tint.opacity(0.25))
                                : AnyShapeStyle(.quaternary),
                            in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.bottom, 8)
    }

    // MARK: - date-grouped grid

    private var photoSections: some View {
        let groups = Dictionary(grouping: appState.visiblePhotos) { item -> String in
            guard let captured = item.info?.captured, captured.count >= 8 else {
                return "Unknown date"
            }
            let d = captured.prefix(8)   // "YYYYMMDD"
            let month = Calendar.current.shortMonthSymbols[(Int(d.prefix(4).suffix(2)) ?? 1) - 1]
            return "\(month) \(d.suffix(2)), \(d.prefix(4))"
        }
        let ordered = groups.sorted { a, b in
            (a.value.first?.info?.captured ?? "") > (b.value.first?.info?.captured ?? "")
        }

        return LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
            ForEach(ordered, id: \.key) { date, items in
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 4)],
                              spacing: 4) {
                        ForEach(items) { item in
                            NavigationLink(value: item.handle) {
                                Cell(item: item)
                            }
                            .buttonStyle(.plain)
                            .task {
                                _ = await appState.thumbnail(for: item)
                                // near the end of loaded metadata? fetch next page
                                if let idx = appState.photos.firstIndex(where: { $0.handle == item.handle }),
                                   idx % 50 == 40 {
                                    await appState.loadNextMetadataPage()
                                }
                            }
                        }
                    }
                } header: {
                    Text(date)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                        .background(.background.opacity(0.9))
                }
            }
        }
    }

    // MARK: - cell

    private struct Cell: View {
        @EnvironmentObject var appState: AppState
        let item: PhotoItem

        private var isStarred: Bool { (appState.ratings[item.handle] ?? 0) > 0 }

        var body: some View {
            Group {
                if let thumb = item.thumb, let ui = UIImage(data: thumb) {
                    Image(uiImage: ui).resizable().scaledToFill()
                } else if let info = item.info {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        VStack(spacing: 4) {
                            Text(info.format.displayName).font(.caption2)
                            Text("\(info.size / 1_000_000)MB").font(.caption2)
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
                ZStack {
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
                            .shadow(radius: 1)
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if appState.fullPhotos.contains(item.handle) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.teal)
                        .padding(3)
                        .shadow(radius: 1)
                }
            }
        }
    }
}
