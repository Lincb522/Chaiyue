import UIKit
import UniformTypeIdentifiers

/// 系统文件选择器。SwiftUI 的 fileImporter 在同一层级挂了多个时（书架常驻一个、弹层里再有一个），
/// 点「打开」后的回调可能落到未展开的那个修饰符上被丢掉，所以直接用 UIKit 呈现。
/// 默认以副本方式打开，拿到的是沙盒内的临时文件，不需要安全作用域；
/// 选文件夹不能用副本方式（`asCopy` 传 false），拿到的地址要在安全作用域内读取
enum FilePicker {
    private static var active: Delegate?

    static func present(_ types: [UTType], multiple: Bool = false, asCopy: Bool = true,
                        completion: @escaping ([URL]) -> Void) {
        guard let top = SourcePresenter.topController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        picker.allowsMultipleSelection = multiple
        let delegate = Delegate(completion: completion)
        picker.delegate = delegate
        active = delegate
        top.present(picker, animated: true)
    }

    /// 让用户选一个位置，把文件拷贝过去（「存储到文件」）
    static func export(_ url: URL, completion: @escaping ([URL]) -> Void = { _ in }) {
        guard let top = SourcePresenter.topController() else { return }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        let delegate = Delegate(completion: completion)
        picker.delegate = delegate
        active = delegate
        top.present(picker, animated: true)
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let completion: ([URL]) -> Void

        init(completion: @escaping ([URL]) -> Void) {
            self.completion = completion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            FilePicker.active = nil
            guard !urls.isEmpty else { return }
            completion(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            FilePicker.active = nil
        }
    }
}
