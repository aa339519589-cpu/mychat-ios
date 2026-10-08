import SwiftUI
import UIKit

struct CameraImagePicker: UIViewControllerRepresentable {
    let completed: (Data?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completed: completed)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completed: (Data?) -> Void

        init(completed: @escaping (Data?) -> Void) {
            self.completed = completed
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completed(nil)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            completed(image?.jpegData(compressionQuality: 0.92))
        }
    }
}

// The attachment sheet reads only the photos the user has granted access to.
// A PhotosPicker remains available even without granting library-wide access.
import Photos
import PhotosUI

@MainActor final class RecentPhotoLibrary: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    override init() { super.init(); PHPhotoLibrary.shared().register(self) }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    func reload() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { assets = []; return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 24
        let result = PHAsset.fetchAssets(with: .image, options: options)
        assets = (0..<result.count).map { result.object(at: $0) }
    }
    func requestAccess() async { _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite); reload() }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) { Task { @MainActor in self.reload() } }
    func manageLimitedAccess() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = controller.presentedViewController { controller = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }
    func originalImage(_ asset: PHAsset) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: info?[PHImageErrorKey] as? Error ?? AttachmentPreparationError.invalidImage) }
            }
        }
    }
}

struct RecentPhotoStrip: View {
    @StateObject private var library = RecentPhotoLibrary()
    @Environment(\.scenePhase) private var scenePhase
    @State private var importingID: String?
    @State private var importError: String?
    let camera: () -> Void
    let selected: (Data, String) async -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    Button(action: camera) {
                        VStack(spacing: 8) {
                            Image(systemName: "camera").font(MyChatSystemFont.appFont(size: 18, weight: .regular))
                            Text("相机").font(MyChatTypography.navigation)
                        }
                            .frame(width: 100, height: 100)
                            .background(MyChatTheme.controlSurface, in: RoundedRectangle(cornerRadius: 24))
                    }
                    .buttonStyle(MyChatBubblePressStyle(glassSurface: false))
                    .accessibilityLabel("拍照")
                    ForEach(library.assets, id: \.localIdentifier) { asset in
                        Button {
                            guard importingID == nil else { return }
                            importingID = asset.localIdentifier
                            Task {
                                do { await selected(try await library.originalImage(asset), PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "Photo.jpg") }
                                catch { importError = error.localizedDescription }
                                importingID = nil
                            }
                        } label: {
                            RecentPhotoThumbnail(asset: asset)
                                .frame(width: 100, height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 24))
                                .contentShape(RoundedRectangle(cornerRadius: 24))
                                .accessibilityHidden(true)
                                .overlay {
                                    if importingID == asset.localIdentifier {
                                        ProgressView().padding(10).background(.regularMaterial, in: Circle())
                                    }
                                }
                        }
                        .buttonStyle(MyChatBubblePressStyle(glassSurface: false))
                        .accessibilityLabel("添加最近照片")
                    }
                    if library.assets.isEmpty { permissionCard }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .frame(height: 100)
            if library.status == .limited {
                Button("管理照片访问权限") { library.manageLimitedAccess() }
                    .font(MyChatTypography.caption)
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("photos.limited-access")
            }
        }
        .alert("无法添加照片", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) { Button("好", role: .cancel) {} } message: { Text(importError ?? "") }
        .task { library.reload() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { library.reload() } }
    }
    private var permissionCard: some View {
        Button {
            switch library.status {
            case .notDetermined: Task { await library.requestAccess() }
            case .denied:
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            default: break
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(permissionTitle).font(MyChatSystemFont.appFont(size: 16, weight: .medium))
                Text(permissionSubtitle).font(MyChatTypography.caption).foregroundStyle(MyChatTheme.secondaryText)
                if library.status == .notDetermined || library.status == .denied {
                    Text(library.status == .denied ? "打开设置" : "允许访问照片")
                        .font(MyChatTypography.caption).foregroundStyle(MyChatTheme.text)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(MyChatTheme.raised, in: Capsule())
                }
            }
            .frame(width: 218, height: 72, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(MyChatTheme.selected, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("photos.permission-card")
    }
    private var permissionTitle: String {
        switch library.status {
        case .notDetermined: "查看最近照片"
        case .denied, .restricted: "照片访问已关闭"
        default: "没有最近照片"
        }
    }
    private var permissionSubtitle: String {
        library.status == .notDetermined ? "允许访问后即可从这里直接添加照片。" : "你仍可使用上方的“照片”按钮选择图片。"
    }
}

private struct RecentPhotoThumbnail: View {
    let asset: PHAsset
    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID?
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                else { MyChatTheme.selected.overlay { Image(systemName: "photo").foregroundStyle(MyChatTheme.secondaryText) } }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: asset.localIdentifier) {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = false
            requestID = PHImageManager.default().requestImage(for: asset,
                targetSize: CGSize(width: 300, height: 300), contentMode: .aspectFill, options: options) { image, _ in
                guard let image else { return }
                Task { @MainActor in thumbnail = image }
            }
        }
        .onDisappear { if let requestID { PHImageManager.default().cancelImageRequest(requestID) } }
    }
}
