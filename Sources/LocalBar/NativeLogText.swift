import SwiftUI
import AppKit
import LocalBarCore

struct NativeLogText: NSViewRepresentable {
    let content: LogContent
    let theme: LogTheme?
    let font: NSFont
    @Environment(\.colorScheme) private var colorScheme

    final class Coordinator {
        var content: LogContent?
        var theme: LogTheme?
        var font: NSFont?
        var dark: Bool?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let cache = context.coordinator
        let dark = colorScheme == .dark
        guard let view = scroll.documentView as? NSTextView,
              cache.content != content || cache.theme != theme || cache.font != font || cache.dark != dark else { return }
        cache.content = content; cache.theme = theme; cache.font = font; cache.dark = dark
        let origin = scroll.contentView.bounds.origin
        let atBottom = view.string.isEmpty || scroll.contentView.bounds.maxY >= view.bounds.maxY - 24
        let selection = view.selectedRange()
        let foreground = theme?.foreground.nsColor ?? .textColor
        let background = theme?.background.nsColor ?? .textBackgroundColor
        view.backgroundColor = background
        scroll.backgroundColor = background
        let selectedBackground = theme?.selectionBackground?.nsColor ?? .selectedTextBackgroundColor
        view.selectedTextAttributes = [
            .backgroundColor: selectedBackground,
            .foregroundColor: theme?.selectionForeground?.nsColor ?? (theme == nil ? .selectedTextColor : foreground)
        ]
        let styled = NSMutableAttributedString(string: content.text, attributes: [.font: font, .foregroundColor: foreground])
        var attributes: [ANSIStyle: [NSAttributedString.Key: Any]] = [:]
        for run in content.runs {
            if attributes[run.style] == nil {
                let style = run.style
                var fg = style.foreground.map { color($0, dark: dark) } ?? foreground
                var bg = style.background.map { color($0, dark: dark) } ?? background
                if style.inverse { swap(&fg, &bg) }
                if style.dim { fg = fg.blended(withFraction: 0.45, of: bg) ?? fg }
                var traits: NSFontTraitMask = []
                if style.bold { traits.insert(.boldFontMask) }
                if style.italic { traits.insert(.italicFontMask) }
                var values: [NSAttributedString.Key: Any] = [
                    .foregroundColor: fg,
                    .font: traits.isEmpty ? font : NSFontManager.shared.convert(font, toHaveTrait: traits)
                ]
                if style.background != nil || style.inverse { values[.backgroundColor] = bg }
                if style.underline { values[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if style.strikethrough { values[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                attributes[style] = values
            }
            styled.addAttributes(attributes[run.style]!, range: run.range)
        }
        view.textStorage?.setAttributedString(styled)
        let location = min(selection.location, styled.length)
        view.setSelectedRange(NSRange(location: location, length: min(selection.length, styled.length - location)))
        if atBottom && selection.length == 0 { view.scrollToEndOfDocument(nil) }
        else { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
    }

    private func color(_ color: ANSIColor, dark: Bool) -> NSColor {
        switch color {
        case let .rgb(r, g, b): return NSColor(srgbRed: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: 1)
        case let .indexed(index):
            if let imported = theme?.palette[index] { return imported.nsColor }
            if index < 16 {
                let colors = dark
                    ? ["333333", "ef6b73", "97c990", "e5c07b", "78a9ef", "c792ea", "70c7d4", "d8d8d8", "888888", "ff9090", "b1e0a8", "ffe0a3", "a1c4ff", "e0b1ff", "a0e4ef", "ffffff"]
                    : ["000000", "b02030", "267326", "896000", "245fbb", "8640a6", "006c7c", "b0b0b0", "666666", "ce3040", "368036", "a07000", "3470cc", "9750b8", "007d8d", "eeeeee"]
                return TerminalColor(hex: colors[index])!.nsColor
            }
            if index >= 232 {
                let level = Double(8 + (index - 232) * 10) / 255
                return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
            }
            let levels = [0.0, 95, 135, 175, 215, 255]
            let n = index - 16
            return NSColor(srgbRed: levels[n / 36] / 255, green: levels[(n / 6) % 6] / 255, blue: levels[n % 6] / 255, alpha: 1)
        }
    }
}
