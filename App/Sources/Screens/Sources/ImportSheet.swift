import CoreImage
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// 导入书源（原型 `importSheet`）：粘贴、链接、文件、扫码。书源、替换规则、朗读引擎等都按内容自动识别
struct ImportSheet: View {
    var title = "导入书源"
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var linking = false
    @State private var link = ""
    @State private var scanning = false
    @State private var choosingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var bounces: [String: Int] = [:]

    private static let tiles: [(symbol: String, title: String)] = [
        ("doc.on.clipboard", "粘贴"), ("link", "链接"), ("folder", "文件"), ("qrcode.viewfinder", "扫码"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: title)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                ForEach(Self.tiles, id: \.title) { tile in
                    Button {
                        tap(tile.title)
                    } label: {
                        VStack(spacing: 12) {
                            Image(icon: tile.symbol)
                                .font(.system(size: 24))
                                .foregroundStyle(Tok.gFg)
                                .symbolEffect(.bounce.down, value: bounces[tile.title] ?? 0)
                                .frame(width: 54, height: 54)
                                .background(Tok.gFill2, in: Circle())
                            Text(tile.title)
                                .font(.ui(14))
                                .foregroundStyle(Tok.gFg2)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 118)
                        .background(Tok.gFill, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }
                    .buttonStyle(.pressSoft)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 2)
            .padding(.bottom, 30)
            Spacer(minLength: 0)
        }
        .qSheet([.height(340)])
        .alert("导入链接", isPresented: $linking) {
            TextField("https://", text: $link)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("导入") { finish(text: link) }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await readQR(from: item) }
        }
        .fullScreenCover(isPresented: $scanning) {
            QRScanScreen { text in
                scanning = false
                finish(text: text)
            }
        }
    }

    private func tap(_ title: String) {
        bounces[title, default: 0] += 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch title {
        case "粘贴":
            guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                app.island.show("doc.on.clipboard", "剪贴板为空", danger: true)
                return
            }
            finish(text: text)
        case "链接":
            link = ""
            linking = true
        case "文件":
            FilePicker.present([.json, .text, .data], multiple: true) { urls in
                dismiss()
                for url in urls { app.importConfigFile(url) }
            }
        default:
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                scanning = true
            } else {
                choosingPhoto = true
            }
        }
    }

    /// 图标弹一下再关闭弹层，之后由灵动岛显示导入结果
    private func finish(text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            dismiss()
            await app.importText(text)
        }
    }

    private func readQR(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let text = await Task.detached(priority: .userInitiated) { Self.qrText(in: data) }.value
        guard let text else {
            app.island.show("qrcode", "图片里没有二维码", danger: true)
            return
        }
        finish(text: text)
    }

    nonisolated private static func qrText(in data: Data) -> String? {
        guard let image = CIImage(data: data),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        return detector.features(in: image).lazy.compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}

// MARK: - 扫码

private struct QRScanScreen: View {
    let onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QRScanner(onFound: onFound)
                .ignoresSafeArea()
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.85), lineWidth: 2)
                .frame(width: 240, height: 240)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            CircleButton(systemName: "xmark") { dismiss() }
                .padding(.trailing, 20)
                .padding(.top, 8)
        }
        .background(.black)
    }
}

/// 系统扫码器放在容器里：出现在屏幕上之后才能开始扫描
private struct QRScanner: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerHost {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return ScannerHost(scanner: scanner)
    }

    func updateUIViewController(_ controller: ScannerHost, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        private var done = false

        init(onFound: @escaping (String) -> Void) {
            self.onFound = onFound
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let text = code.payloadStringValue, !text.isEmpty {
                    done = true
                    dataScanner.stopScanning()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onFound(text)
                    return
                }
            }
        }
    }

    final class ScannerHost: UIViewController {
        let scanner: DataScannerViewController

        init(scanner: DataScannerViewController) {
            self.scanner = scanner
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(scanner)
            scanner.view.frame = view.bounds
            scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scanner.view)
            scanner.didMove(toParent: self)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            try? scanner.startScanning()
        }
    }
}
