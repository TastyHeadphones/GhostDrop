import SwiftUI
import UIKit

struct IOSDocumentPicker: UIViewControllerRepresentable {
    let didPickURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(didPickURL: didPickURL)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let didPickURL: (URL) -> Void

        init(didPickURL: @escaping (URL) -> Void) {
            self.didPickURL = didPickURL
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            didPickURL(url)
        }
    }
}
