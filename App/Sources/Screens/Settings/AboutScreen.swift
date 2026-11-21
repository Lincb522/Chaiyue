import SwiftUI

/// 关于：图标、名称、版本与开源许可
struct AboutScreen: View {
    @State private var licenses = false
    @State private var shown = false
    @State private var spin = 0

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(short) (\(build))"
    }

    var body: some View {
        PageScaffold(title: "关于", largeTitle: false) {
            VStack(spacing: 14) {
                Image("Logo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .coverShadow(lifted: true)
                    .rotation3DEffect(.degrees(Double(spin) * 360), axis: (0, 1, 0), perspective: 0.5)
                    .onTapGesture {
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        withAnimation(.spring(duration: 0.9, bounce: 0.2)) { spin += 1 }
                    }
                    .scaleEffect(shown ? 1 : 0.6)
                    .opacity(shown ? 1 : 0)
                LogoMark()
                    .frame(width: 116)
                    .padding(.top, 10)
                    .entrance(shown, delay: 0.08, rise: 12)
                Text(version)
                    .font(.num(13))
                    .foregroundStyle(Tok.fg3)
                    .entrance(shown, delay: 0.12, rise: 12)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 96)
            .padding(.bottom, 40)

            CardGroup {
                Button {
                    licenses = true
                } label: {
                    SettingRow(icon: "doc.text", title: "开源许可")
                }
                .buttonStyle(.row)
            }
            .padding(.horizontal, 16)
            .entrance(shown, delay: 0.16, rise: 16)
        }
        .sheet(isPresented: $licenses) { LicensesSheet() }
        .onAppear {
            withAnimation(.bouncy) { shown = true }
        }
    }
}

private struct LicensesSheet: View {
    private static let items: [(name: String, license: String, url: String)] = [
        ("Legado", "GPL-3.0", "https://github.com/gedoor/legado"),
        ("SwiftSoup", "MIT", "https://github.com/scinfu/SwiftSoup"),
        ("Kanna", "MIT", "https://github.com/tid-kijyun/Kanna"),
        ("Sextant", "MIT", "https://github.com/KittyMac/Sextant"),
        ("ZIPFoundation", "MIT", "https://github.com/weichsel/ZIPFoundation"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "开源许可")
            ScrollView {
                CardGroup(separatorInset: 14) {
                    ForEach(Self.items, id: \.name) { item in
                        Link(destination: URL(string: item.url)!) {
                            SettingRow(title: item.name) {
                                Text(item.license)
                            }
                        }
                        .buttonStyle(.glassRow)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .environment(\.onGlass, true)
        .qSheet([.medium])
    }
}
