import SwiftUI

struct AppThemeView: View {
    @AppStorage("themeMode") private var themeMode = "0"
    @AppStorage("readerTheme") private var readerTheme = "wechat"
    @AppStorage("epubTheme") private var epubTheme = "system"
    @AppStorage("readerUseBackgroundImage") private var useBackgroundImage = false
    @AppStorage("bookshelfLayout") private var bookshelfLayout = "grid3"
    @AppStorage("inkPreviousThemeMode") private var previousMode = "0"
    @AppStorage("inkPreviousReaderTheme") private var previousReaderTheme = "wechat"
    @AppStorage("inkPreviousEPUBTheme") private var previousEPUBTheme = "system"
    @AppStorage("inkPreviousCustomBackground") private var previousCustomBackground = false
    @AppStorage("inkPreviousBookshelfLayout") private var previousLayout = "grid3"
    @State private var includesReader = true

    private let ink = Color(red: 0.15, green: 0.18, blue: 0.17)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                VStack(spacing: 14) {
                    Rectangle().fill(Color(red: 0.66, green: 0.58, blue: 0.40))
                        .frame(width: 32, height: 1)
                    Text("水墨江湖")
                        .tracking(8)
                        .font(.system(size: 30, weight: .medium, design: .serif))
                    Text("一卷山河 · 万里剑气")
                        .tracking(4).font(.footnote)
                        .foregroundStyle(ink.opacity(0.6))
                }
                .padding(.top, 24)

                themePreview

                HStack(alignment: .top, spacing: 16) {
                    InkSeal(character: "墨")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("把江湖，藏进每一页")
                            .font(.system(.title3, design: .serif))
                        Text("宣纸为底，远山入卷。用温润的留白与一抹朱砂，陪你读过书里的山河。")
                            .font(.subheadline)
                            .foregroundStyle(ink.opacity(0.66))
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 0) {
                    paletteSwatch("宣纸", color: ReadingTheme.inkPaper)
                    Spacer()
                    paletteSwatch("松墨", color: ink)
                    Spacer()
                    paletteSwatch("山岚", color: Color(red: 0.52, green: 0.58, blue: 0.53))
                    Spacer()
                    paletteSwatch("朱砂", color: ReadingTheme.cinnabar)
                }
                .padding(18)
                .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))

                if themeMode != "4" {
                    Toggle("同时应用阅读配色", isOn: $includesReader)
                        .font(.subheadline)
                        .tint(ReadingTheme.cinnabar)
                    Text("阅读页使用更淡的山水底纹，保留当前字号与排版。")
                        .font(.caption).foregroundStyle(ink.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: applyTheme) {
                        Text("应用水墨主题")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(ReadingTheme.cinnabar, in: Capsule())
                    .accessibilityIdentifier("theme.applyInk")
                } else {
                    Label("水墨江湖 · 使用中", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ReadingTheme.cinnabar)
                    Button("恢复之前的主题", action: restoreTheme)
                        .font(.subheadline)
                        .foregroundStyle(ink.opacity(0.65))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("theme.restore")
                }
            }
            .foregroundStyle(ink)
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(ReadingTheme.inkPaper.ignoresSafeArea())
        .navigationTitle("主题")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.light)
    }

    private var themePreview: some View {
        HStack(alignment: .top, spacing: 14) {
            previewPage(title: "书架") {
                VStack(spacing: 10) {
                    previewBook("山海入梦来", author: "林间客")
                    previewBook("长夜里的灯", author: "南风")
                }
            }
            previewPage(title: "阅读") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("第一章  山河故人")
                        .font(.system(size: 12, weight: .medium, design: .serif))
                        .frame(maxWidth: .infinity)
                    Text("山中一夜雨，树杪百重泉。\n\n少年收起旧书，推开木窗。远山隐在云里，一叶轻舟正缓缓渡过江面。\n\n他知道，故事才刚刚开始。")
                        .font(.system(size: 10, design: .serif))
                        .lineSpacing(6)
                    Spacer(minLength: 0)
                    HStack { Spacer(); InkSeal().scaleEffect(0.55, anchor: .bottomTrailing) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("水墨江湖主题预览：宣纸色书架、淡墨山水阅读背景和朱砂进度条")
    }

    private func previewPage<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.system(size: 19, weight: .semibold, design: .serif))
                Spacer()
                Image(systemName: title == "书架" ? "plus" : "ellipsis").font(.caption)
            }
            content()
            Spacer(minLength: 0)
            HStack {
                Image(systemName: "books.vertical")
                Spacer()
                Image(systemName: "safari")
                Spacer()
                Image(systemName: ReadingTheme.mountainSymbol)
                Spacer()
                Image(systemName: "seal")
            }
            .font(.system(size: 10))
            .foregroundStyle(ReadingTheme.cinnabar)
            .padding(9)
            .background(.white.opacity(0.65), in: Capsule())
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .frame(height: 312)
        .background { InkLandscapeBackground(opacity: title == "书架" ? 0.48 : 0.18) }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.9), lineWidth: 1.5) }
        .shadow(color: ink.opacity(0.08), radius: 12, x: 0, y: 6)
    }

    private func previewBook(_ title: String, author: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            BookCoverArtwork(title: title, author: author, width: 30, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 10, weight: .medium, design: .serif)).lineLimit(1)
                Text(author).font(.system(size: 8)).foregroundStyle(ink.opacity(0.6))
                Capsule().fill(ReadingTheme.cinnabar.opacity(0.5)).frame(width: 26, height: 2)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private func paletteSwatch(_ name: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Circle().fill(color).frame(width: 24, height: 24)
                .overlay { Circle().strokeBorder(ink.opacity(0.1), lineWidth: 0.5) }
            Text(name).font(.caption2).foregroundStyle(ink.opacity(0.7))
        }
    }

    private func applyTheme() {
        previousMode = themeMode
        previousReaderTheme = readerTheme
        previousEPUBTheme = epubTheme
        previousCustomBackground = useBackgroundImage
        previousLayout = bookshelfLayout
        bookshelfLayout = "list"
        if includesReader {
            readerTheme = "ink"
            epubTheme = "ink"
            useBackgroundImage = false
        }
        themeMode = "4"
    }

    private func restoreTheme() {
        if readerTheme == "ink", !useBackgroundImage {
            readerTheme = previousReaderTheme
            useBackgroundImage = previousCustomBackground
        }
        if epubTheme == "ink" { epubTheme = previousEPUBTheme }
        if bookshelfLayout == "list" { bookshelfLayout = previousLayout }
        themeMode = ["0", "1", "2", "3"].contains(previousMode) ? previousMode : "0"
    }
}
