import Photos
import PhotosUI
import SwiftUI

#if os(iOS)
/// iOS 15-compatible photo/video picker.
///
/// SwiftUI's `PhotosPicker` (and `PhotosPickerItem`) are iOS 16+, so this wraps
/// the UIKit `PHPickerViewController`, which is available from iOS 14. Results
/// are mapped to `[MediaSource]` via `MediaLibrary.sources(forPickerResults:)`:
/// an asset identifier when the library is readable (keeps the original
/// filename and capture date), otherwise the item provider for a lazy copy at
/// export time.
struct PhotoPicker: UIViewControllerRepresentable {
    var selectionLimit: Int = 50
    var onPicked: ([MediaSource]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = selectionLimit
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPicked: ([MediaSource]) -> Void

        init(onPicked: @escaping ([MediaSource]) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let sources = MediaLibrary.sources(forPickerResults: results)
            picker.dismiss(animated: true)
            onPicked(sources)
        }
    }
}
#endif

#if os(macOS)
/// macOS has no `PHPickerViewController` equivalent, so this is a native
/// SwiftUI grid backed directly by `PHPhotoLibrary`. It requires photo-library
/// read access up front (callers already gate showing this on `canRead`), and
/// hands back asset identifiers the same way the iOS picker does when the
/// library is readable.
struct PhotoPicker: View {
    var selectionLimit: Int = 50
    var onPicked: ([MediaSource]) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PhotoPickerModel()
    @State private var selected: [String] = []

    var body: some View {
        NavigationRoot {
            Group {
                if !model.canRead {
                    EmptyState(symbol: "photo.badge.exclamationmark",
                               title: "Photo access is off",
                               message: "Allow photo access in System Settings to choose photos.")
                } else if model.isLoading {
                    ProgressView("Loading photos…")
                } else if model.assets.isEmpty {
                    EmptyState(symbol: "photo.on.rectangle.angled", title: "No photos found", message: "")
                } else {
                    grid
                }
            }
            .navigationTitle("Choose Photos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.isEmpty ? "Add" : "Add \(selected.count)") { finish() }
                        .disabled(selected.isEmpty)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .onAppear { model.load() }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                ForEach(model.assets, id: \.localIdentifier) { asset in
                    PhotoPickerThumbnail(
                        asset: asset,
                        isSelected: selected.contains(asset.localIdentifier),
                        imageManager: model.imageManager,
                        action: { toggle(asset.localIdentifier) }
                    )
                }
            }
            .padding(8)
        }
    }

    private func toggle(_ id: String) {
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
        } else if selected.count < selectionLimit {
            selected.append(id)
        }
    }

    private func finish() {
        let sources = selected.map { MediaSource.asset(localIdentifier: $0) }
        dismiss()
        onPicked(sources)
    }
}

@MainActor
private final class PhotoPickerModel: ObservableObject {
    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var isLoading = false
    let imageManager = PHCachingImageManager()

    var canRead: Bool { MediaLibrary.isReadable }

    func load() {
        guard canRead, assets.isEmpty, !isLoading else { return }
        isLoading = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let fetched = PHAsset.fetchAssets(with: PhotoAlbumStore.allPhotosOptions())
            var result: [PHAsset] = []
            result.reserveCapacity(fetched.count)
            fetched.enumerateObjects { asset, _, _ in result.append(asset) }
            await MainActor.run {
                self?.assets = result
                self?.isLoading = false
            }
        }
    }
}

private struct PhotoPickerThumbnail: View {
    let asset: PHAsset
    let isSelected: Bool
    let imageManager: PHCachingImageManager
    let action: () -> Void

    @State private var image: NSImage?
    @State private var requestID: PHImageRequestID?
    private static let targetSize = CGSize(width: 220, height: 220)

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color.secondary.opacity(0.15))
                    }
                }
                .frame(width: 110, height: 110)
                .clipped()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .white)
                    .shadow(radius: 2)
                    .padding(4)
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onAppear { startLoading() }
        .onDisappear { cancelLoading() }
    }

    private func startLoading() {
        guard image == nil, requestID == nil else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        requestID = imageManager.requestImage(
            for: asset, targetSize: Self.targetSize, contentMode: .aspectFill, options: options
        ) { result, _ in
            guard let result else { return }
            DispatchQueue.main.async { self.image = result }
        }
    }

    private func cancelLoading() {
        if let requestID { imageManager.cancelImageRequest(requestID) }
        requestID = nil
    }
}
#endif
