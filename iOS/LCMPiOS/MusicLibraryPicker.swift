import MediaPlayer
import SwiftUI
import LibraryCore

/// The system picker for songs of the Music library. Only songs stored on the device without
/// DRM can be read, so cloud-only and protected songs are not offered.
struct MusicLibraryPicker: UIViewControllerRepresentable {
    let done: ([M3U8Item]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }
    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = true
        picker.showsCloudItems = false
        picker.showsItemsWithProtectedAssets = false
        picker.prompt = "LCMPに登録する曲を選んでください"
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: MPMediaPickerController, context: Context) {}

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let done: ([M3U8Item]) -> Void
        init(done: @escaping ([M3U8Item]) -> Void) { self.done = done }
        func mediaPicker(_ picker: MPMediaPickerController, didPickMediaItems collection: MPMediaItemCollection) {
            done(collection.items.compactMap { item in
                guard !item.hasProtectedAsset, !item.isCloudItem, let url = item.assetURL else { return nil }
                return M3U8Item(url: url, title: item.title)
            })
        }
        func mediaPickerDidCancel(_ picker: MPMediaPickerController) { done([]) }
    }

    /// Asks for access once; true when the library may be read.
    static func authorize() async -> Bool {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}
