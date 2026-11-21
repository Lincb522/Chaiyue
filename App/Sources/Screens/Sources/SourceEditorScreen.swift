import ReaderModels
import ReaderServices
import SwiftUI
import UIKit

/// 书源 JSON 编辑（Legado 字段原样），保存时校验格式与必填项
struct SourceEditorScreen: View {
    let url: String?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false

    private static let template = """
    {
      "bookSourceName": "",
      "bookSourceUrl": "",
      "bookSourceGroup": "",
      "searchUrl": "",
      "exploreUrl": "",
      "ruleSearch": {},
      "ruleExplore": {},
      "ruleBookInfo": {},
      "ruleToc": {},
      "ruleContent": {}
    }
    """

    var body: some View {
        ZStack(alignment: .top) {
            ScreenBackground()
            CodeEditor(text: $text)
                .padding(.top, 50)
                .ignoresSafeArea(edges: .bottom)
            PageBar(title: url == nil ? "新建书源" : "编辑书源", scrolled: true) {
                CircleButton(systemName: "checkmark") { save() }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let url, let source = app.library.sources.source(for: url) else {
            text = Self.template
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        text = (try? encoder.encode(source)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private func save() {
        let source: BookSource
        do {
            guard let first = try SourceImport.bookSources(from: Data(text.utf8)).first else { throw SourceImportError.empty }
            source = first
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            app.island.show("exclamationmark.triangle", "JSON 格式有误", danger: true)
            return
        }
        guard !source.bookSourceName.trimmingCharacters(in: .whitespaces).isEmpty,
              !source.bookSourceUrl.trimmingCharacters(in: .whitespaces).isEmpty else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            app.island.show("exclamationmark.triangle", "书源名称和地址不能为空", danger: true)
            return
        }
        app.library.sources.save(source, originalURL: url)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        app.island.show("checkmark", "已保存")
        dismiss()
    }
}

/// 等宽代码编辑：关闭智能引号与自动更正，避免把 JSON 的引号替换成中文引号
struct CodeEditor: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = UIColor(Tok.fg)
        view.tintColor = UIColor(Tok.accent)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 14, bottom: 80, right: 14)
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}
