import SwiftUI
import UIKit
import CoreText

enum MyChatTheme {
    static let brand = Color.dynamic(light: 0xC86F4E, dark: 0xD68B68)
    static let onBrand = Color.dynamic(light: 0xFFFFFF, dark: 0x1C1512)
    static let accent = brand
    static let canvas = Color.dynamic(light: 0xF9F9F7, dark: 0x151515)
    static let sidebar = Color.dynamic(light: 0xF3F3F0, dark: 0x111111)
    static let sidebarSecondary = Color.dynamic(light: 0x52514E, dark: 0x9A9A93)
    static let raised = Color.dynamic(light: 0xFFFFFF, dark: 0x202020)
    static let composer = Color.dynamic(light: 0xFDFDFB, dark: 0x292929)
    static let selected = Color.dynamic(light: 0xE7E6E1, dark: 0x272727)
    static let settingsAvatar = Color.dynamic(light: 0xE7E6E2, dark: 0x0B0B0B)
    static let userBubble = Color.dynamic(light: 0xEFEFED, dark: 0x2C2C2A)
    static let libraryCanvas = canvas
    static let text = Color.dynamic(light: 0x131313, dark: 0xF8F8F6)
    static let secondaryText = Color.dynamic(light: 0x6E6D67, dark: 0xAAA9A1)
    static let border = Color.dynamic(light: 0xD6D5D0, dark: 0x3D3D3F)
    static let overlay = Color.black.opacity(0.34)

    static let bubbleHighlight = Color.dynamic(light: 0xFFFFFF, dark: 0x1A1A1A)
    static let bubbleMidtone = Color.dynamic(light: 0xFDFDFB, dark: 0x181818)
    static let bubbleShade = Color.dynamic(light: 0xFAFAF8, dark: 0x151515)
    static let controlSurface = Color.dynamic(light: 0xF0EFED, dark: 0x303030)
    static let composerControlSurface = Color.dynamic(light: 0xF0EFED, dark: 0x353535)
    static let composerControlBorder = Color.dynamic(light: 0xF0EFED, dark: 0x464648)
    static let composerActionSurface = Color.dynamic(light: 0x171717, dark: 0xF8F8F6)
    static let thinking = Color.dynamic(light: 0xC86F4E, dark: 0xC86F4E)
    static let sendActionSurface = thinking
    static let sendActionForeground = Color.white
    static let composerActionForeground = Color.dynamic(light: 0xFFFFFF, dark: 0x202020)
    static let newChatSurface = Color.dynamic(light: 0x242424, dark: 0xF9F9F8)
    static let newChatForeground = Color.dynamic(light: 0xFFFFFF, dark: 0x242424)
    static let headerControlSurface = Color.dynamic(light: 0xFFFFFF, dark: 0x292929)
    static let settingsControlSurface = Color.dynamic(light: 0xF0EFEB, dark: 0x292929)
    static let headerControlForeground = Color.dynamic(light: 0x353532, dark: 0xD1D1C8)
    static let newChatGlyphFill = Color.dynamic(light: 0x353532, dark: 0xFDFDFB)
    static let newChatGlyphPlus = Color.dynamic(light: 0xFDFDFB, dark: 0x343432)
    static let inlineCodeSurface = Color.dynamic(light: 0xECECE8, dark: 0x262626)
    static let inlineCodeText = Color.dynamic(light: 0x708CB8, dark: 0x708CB8)
    static let codeString = Color.dynamic(light: 0x608344, dark: 0xA7BA88)
    static let codeNumber = Color.dynamic(light: 0xA38A43, dark: 0xCDB875)
    static let codeKeyword = Color.dynamic(light: 0x9B6CB3, dark: 0xC29DD8)

    static let drawerWidthRatio: CGFloat = 0.73
    static let controlSize: CGFloat = 44
    static let composerRadius: CGFloat = 24
    static let messageBubbleRadius: CGFloat = 24
    static let chatCardRadius: CGFloat = 20
    static let markdownTableRadius: CGFloat = 8
    static let sidebarInset: CGFloat = 24
    static let sidebarDestinationHeight: CGFloat = 50
    static let sidebarConversationHeight: CGFloat = 50
    static let composerControlSize: CGFloat = 36
}

enum MyChatTypography {
    static let appDefault = MyChatSystemFont.appFont(for: .body, weight: .regular)
    static let brandHero = MyChatSystemFont.appFont(size: 32, relativeTo: .largeTitle, weight: .semibold)
    static let brandSidebar = MyChatSystemFont.appSerifFont(size: 25, relativeTo: .title2, weight: .medium)
    static let pageTitleEditorial = MyChatSystemFont.appFont(size: 25, relativeTo: .title1, weight: .semibold)
    static let pageTitleUtility = MyChatSystemFont.appFont(size: 17, relativeTo: .headline, weight: .semibold)
    static let emptyStatePrompt = MyChatSystemFont.appSerifFont(size: 24, relativeTo: .title2, weight: .medium)

    static let responseH1 = MyChatSystemFont.serif(size: 23, weight: .semibold, relativeTo: .title2)
    static let responseH2 = MyChatSystemFont.serif(size: 21, weight: .semibold, relativeTo: .headline)
    static let responseH3 = MyChatSystemFont.serif(size: 19, weight: .semibold, relativeTo: .body)
    static let responseBodySize: CGFloat = 17
    static let responseBody = MyChatSystemFont.serif(size: responseBodySize, weight: .regular, relativeTo: .body)
    static let responseStrong = MyChatSystemFont.serif(size: responseBodySize, weight: .bold, relativeTo: .body)
    static let responseItalic = MyChatSystemFont.italic(size: responseBodySize, relativeTo: .body)
    static let thoughtBodySize = responseBodySize
    static let thoughtHanSize = responseHanSize
    static let thoughtBody = MyChatSystemFont.serif(size: thoughtBodySize, weight: .regular, relativeTo: .body)
    static let thoughtStrong = MyChatSystemFont.serif(size: thoughtBodySize, weight: .bold, relativeTo: .body)
    static let thoughtItalic = MyChatSystemFont.italic(size: thoughtBodySize, relativeTo: .body)
    static let reasoningSummaryBodySize: CGFloat = 19
    static let reasoningSummaryBody = MyChatSystemFont.serif(size: reasoningSummaryBodySize, weight: .regular, relativeTo: .body)
    static let thoughtPreview = MyChatSystemFont.font(size: 17, weight: .regular, relativeTo: .body)

    static let userMessage = MyChatSystemFont.userMessageFont(size: 17.5, weight: .regular)
    static let appStatus = MyChatSystemFont.appFont(size: 17, relativeTo: .body, weight: .regular)
    static let composerText = MyChatSystemFont.appFont(size: 18, relativeTo: .body, weight: .regular)
    static let navigation = MyChatSystemFont.appFont(size: 17, relativeTo: .body, weight: .regular)
    static let sidebarPrimary = MyChatSystemFont.appFont(size: 17, relativeTo: .body, weight: .regular)
    static let sidebarConversation = MyChatSystemFont.appFont(size: 17, relativeTo: .body, weight: .regular)
    static let sidebarSection = MyChatSystemFont.appFont(size: 14, relativeTo: .subheadline, weight: .regular)
    static let composerChip = MyChatSystemFont.appFont(size: 14, relativeTo: .subheadline, weight: .regular)
    static let cardTitle = MyChatSystemFont.appFont(size: 16, relativeTo: .body, weight: .semibold)
    static let cardBody = MyChatSystemFont.appFont(size: 16, relativeTo: .body, weight: .medium)
    static let fileTitle = MyChatSystemFont.appFont(size: 19, relativeTo: .headline, weight: .semibold)
    static let metadata = MyChatSystemFont.appFont(size: 14, relativeTo: .subheadline, weight: .regular)
    static let caption = MyChatSystemFont.appFont(size: 12.5, relativeTo: .caption1, weight: .regular)
    static let chip = MyChatSystemFont.appFont(size: 12.5, relativeTo: .caption1, weight: .medium)
    static let button = MyChatSystemFont.appFont(size: 16, relativeTo: .headline, weight: .semibold)
    static let code = MyChatSystemFont.monospaced(size: 13.5, relativeTo: .body)
    static let inlineCode = MyChatSystemFont.monospaced(size: 16, relativeTo: .body)
    static let inlineCodeStrong = MyChatSystemFont.monospaced(size: 16, weight: .semibold, relativeTo: .body)

    static let brandHeroLineSpacing: CGFloat = 0
    static let brandSidebarLineSpacing: CGFloat = 0
    static let editorialTitleLineSpacing: CGFloat = 3
    static let utilityTitleLineSpacing: CGFloat = 4
    static let responseTracking: CGFloat = 0
    static let responseHanSize: CGFloat = 17.5
    // Keep the Latin response metrics untouched; Chinese body copy uses a
    // tighter Han-only rhythm to match the reference layout.
    static let responseHanTracking: CGFloat = -0.55
    static let responseHanLineSpacing: CGFloat = 9.8
    static let thoughtBodyLineSpacing = responseBodyLineSpacing
    static let reasoningSummaryBodyLineSpacing: CGFloat = 8
    static let reasoningSummaryHanLineSpacing: CGFloat = 11
    static let thoughtHanLineSpacing = responseHanLineSpacing
    static let sidebarTracking: CGFloat = 0
    static let responseH1LineSpacing: CGFloat = 3
    static let responseH2LineSpacing: CGFloat = 4
    static let responseH3LineSpacing: CGFloat = 4
    static let responseBodyLineSpacing: CGFloat = 7.2
    static let userMessageLineSpacing: CGFloat = 3.5
    static let utilityLineSpacing: CGFloat = 4.5
    static let metadataLineSpacing: CGFloat = 5.4
    static let captionLineSpacing: CGFloat = 4.5
    static let codeLineSpacing: CGFloat = 5.5

}

struct NewChatButton: View {
    var height: CGFloat = 44
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .light))
                    .frame(width: 20, height: 20)
                Text("新建对话").font(MyChatSystemFont.appFont(size: 16))
            }
            .foregroundStyle(MyChatTheme.newChatForeground)
            .frame(width: 118, height: height)
            .background(MyChatTheme.newChatSurface, in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(colorScheme == .light ? 0.22 : 0.8), .clear],
                                   startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(MyChatBubblePressStyle(glassSurface: false))
    }
}

enum MyChatSystemFont {
    static let appUIWeight = 385
    private static let weightAxis = NSNumber(value: 0x77676874)

    static let responseWebFontCSS: String = {
        [("AnthropicSerif", "normal"), ("AnthropicSerifItalic", "italic")].compactMap { name, style in
            guard let url = Bundle.main.url(forResource: name, withExtension: "woff2", subdirectory: "ResponseFonts"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return "@font-face { font-family: MyChatResponseSerif; src: url(data:font/woff2;base64,\(data.base64EncodedString())) format('woff2'); font-weight: 300 800; font-style: \(style); font-display: block; }"
        }.joined(separator: "\n")
    }()
    // Keep native font descriptors cached. Typography never loads or registers
    // font files while messages render or the conversation scrolls.
    private static let chineseRegular = UIFont(name: "PingFangSC-Regular", size: 17)?.fontDescriptor
    private static let chineseMedium = UIFont(name: "PingFangSC-Medium", size: 17)?.fontDescriptor
    private static let chineseSemibold = UIFont(name: "PingFangSC-Semibold", size: 17)?.fontDescriptor
    static let responseHanCSSWeight = appUIWeight
    // Share the user's exact PingFang descriptor; English and explicit bold stay unchanged.
    private static let responseHan: UIFontDescriptor? = appHan
    private static let responseHanStrong = chineseSemibold
    private static let appHan: UIFontDescriptor? = {
        let sample = "中文" as CFString
        let range = CFRange(location: 0, length: 2)
        let regular = CTFontCreateForString(UIFont.systemFont(ofSize: 17, weight: .regular), sample, range) as UIFont
        return hanWeightedFont(regular, size: 17).fontDescriptor
    }()

    private static func hanWeightedFont(_ font: UIFont, size: CGFloat) -> UIFont {
        let variations: [NSNumber: NSNumber] = [weightAxis: NSNumber(value: appUIWeight)]
        let descriptor = font.fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variations
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    // CoreText scales a cascade automatically, but SwiftUI's Font(UIFont)
    // bridge reads each fallback descriptor's own point size. Cached Han
    // descriptors carry 17pt; leaving that size in a 12pt caption draws a
    // 17pt glyph inside the caption's smaller line box and clips its top.
    // Normalize after both construction and Dynamic Type scaling. Keep the
    // primary Latin face and the Han face/weight/variation unchanged.
    static func matchingCascadeSize(_ font: UIFont) -> UIFont {
        guard let cascade = font.fontDescriptor.fontAttributes[.cascadeList] as? [UIFontDescriptor],
              !cascade.isEmpty else { return font }
        let resized = cascade.map { $0.addingAttributes([.size: font.pointSize]) }
        return UIFont(descriptor: font.fontDescriptor.addingAttributes([.cascadeList: resized]), size: font.pointSize)
    }

    static func scaledUIFont(_ font: UIFont, relativeTo textStyle: UIFont.TextStyle,
                             compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        matchingCascadeSize(UIFontMetrics(forTextStyle: textStyle).scaledFont(for: font, compatibleWith: traits))
    }

    static func appUIFont(size: CGFloat, weight: UIFont.Weight = .regular,
                          design: UIFontDescriptor.SystemDesign? = nil) -> UIFont {
        let regular = design == .monospaced
            ? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        let designed = design.flatMap { regular.fontDescriptor.withDesign($0) }
        let base = designed.map { UIFont(descriptor: $0, size: size) } ?? regular
        let han: UIFontDescriptor?
        if weight >= .semibold { han = chineseSemibold }
        else if weight >= .medium { han = chineseMedium }
        else { han = appHan }
        guard let han else { return base }
        // A regular Han fallback previously erased the requested heading
        // weight, making Chinese page titles look like floating body labels.
        return matchingCascadeSize(UIFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: [han]]), size: size))
    }

    static func appFont(size: CGFloat, design: UIFontDescriptor.SystemDesign? = nil,
                        weight: UIFont.Weight = .regular) -> Font {
        Font(appUIFont(size: size, weight: weight, design: design))
    }

    static func appFont(size: CGFloat, relativeTo textStyle: UIFont.TextStyle,
                        design: UIFontDescriptor.SystemDesign? = nil,
                        weight: UIFont.Weight = .regular) -> Font {
        let base = appUIFont(size: size, weight: weight, design: design)
        return Font(scaledUIFont(base, relativeTo: textStyle))
    }

    static func appFont(for textStyle: UIFont.TextStyle, design: UIFontDescriptor.SystemDesign? = nil,
                        weight: UIFont.Weight = .regular) -> Font {
        let size: CGFloat
        switch textStyle {
        case .largeTitle: size = 34
        case .title1: size = 28
        case .title2: size = 22
        case .title3: size = 20
        case .headline: size = 17
        case .subheadline: size = 15
        case .body: size = 17
        case .callout: size = 16
        case .footnote: size = 13
        case .caption1: size = 12
        case .caption2: size = 11
        default: size = 17
        }
        return appFont(size: size, relativeTo: textStyle, design: design, weight: weight)
    }

    static func appSerifFont(size: CGFloat, relativeTo textStyle: UIFont.TextStyle,
                             weight: UIFont.Weight = .regular) -> Font {
        Font(appSerifUIFont(size: size, relativeTo: textStyle, weight: weight))
    }

    static func appSerifUIFont(size: CGFloat, relativeTo textStyle: UIFont.TextStyle,
                              weight: UIFont.Weight = .regular) -> UIFont {
        let reference = UIFont(name: "AnthropicSerifWebWeb-TextLight", size: size)
            ?? UIFont.systemFont(ofSize: size, weight: weight)
        let variations: [NSNumber: NSNumber] = [
            weightAxis: NSNumber(value: weight.rawValue >= UIFont.Weight.semibold.rawValue ? 700 : 400),
            NSNumber(value: 0x6F70737A): NSNumber(value: 16)
        ]
        let descriptor = reference.fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variations
        ])
        let serif = UIFont(descriptor: descriptor, size: size)
        let withHan = appHan.map { serif.fontDescriptor.addingAttributes([.cascadeList: [$0]]) }
            .map { UIFont(descriptor: $0, size: size) } ?? serif
        return scaledUIFont(withHan, relativeTo: textStyle)
    }

    static func hanFont(size: CGFloat, strong: Bool = false) -> Font {
        Font(UIFontMetrics(forTextStyle: .body).scaledFont(for: hanUIFont(size: size, strong: strong)))
    }

    static func hanUIFont(size: CGFloat, strong: Bool = false) -> UIFont {
        let descriptor = strong ? responseHanStrong : responseHan
        return descriptor.map { UIFont(descriptor: $0, size: size) }
            ?? UIFont.systemFont(ofSize: size, weight: strong ? .semibold : .regular)
    }

    static func nativeFont(size: CGFloat, weight: UIFont.Weight, serif: Bool = false,
                           relativeTo textStyle: UIFont.TextStyle) -> Font {
        let system = UIFont.systemFont(ofSize: size, weight: weight)
        let descriptor = serif ? (system.fontDescriptor.withDesign(.serif) ?? system.fontDescriptor) : system.fontDescriptor
        return Font(UIFontMetrics(forTextStyle: textStyle).scaledFont(for: UIFont(descriptor: descriptor, size: size)))
    }

    static func font(size: CGFloat, weight: UIFont.Weight, relativeTo textStyle: UIFont.TextStyle) -> Font {
        let baseFont = uiFont(size: size, weight: weight)
        return Font(scaledUIFont(baseFont, relativeTo: textStyle))
    }

    static func userMessageFont(size: CGFloat, weight: UIFont.Weight) -> Font {
        let font = appUIFont(size: size, weight: weight)
        return Font(scaledUIFont(font, relativeTo: .body))
    }

    static func uiFont(size: CGFloat, weight: UIFont.Weight, serif: Bool = false, italic: Bool = false) -> UIFont {
        let base: UIFont
        if serif {
            let bold = weight.rawValue >= UIFont.Weight.semibold.rawValue
            let face = italic ? "AnthropicSerifWebWeb-TextLightItalic" : "AnthropicSerifWebWeb-TextLight"
            let reference = UIFont(name: face, size: size) ?? UIFont.systemFont(ofSize: size, weight: weight)
            let variations: [NSNumber: CGFloat] = [NSNumber(value: 0x77676874): bold ? 700 : 400,
                                                   NSNumber(value: 0x6F70737A): 16]
            let descriptor = reference.fontDescriptor.addingAttributes([
                UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variations
            ])
            base = UIFont(descriptor: descriptor, size: size)
        } else {
            let system = UIFont.systemFont(ofSize: size, weight: weight)
            let descriptor = italic ? (system.fontDescriptor.withSymbolicTraits(.traitItalic) ?? system.fontDescriptor) : system.fontDescriptor
            base = UIFont(descriptor: descriptor, size: size)
        }
        var descriptor = base.fontDescriptor
        let hanDescriptor = serif ? (weight.rawValue >= UIFont.Weight.semibold.rawValue ? responseHanStrong : responseHan)
            : weight.rawValue >= UIFont.Weight.semibold.rawValue ? chineseSemibold
            : weight.rawValue >= UIFont.Weight.medium.rawValue ? chineseMedium : chineseRegular
        if let chinese = hanDescriptor {
            descriptor = descriptor.addingAttributes([.cascadeList: [chinese]])
        }
        return matchingCascadeSize(UIFont(descriptor: descriptor, size: size))
    }

    static func italic(size: CGFloat, relativeTo textStyle: UIFont.TextStyle) -> Font {
        Font(scaledUIFont(uiFont(size: size, weight: .medium, serif: true, italic: true), relativeTo: textStyle))
    }

    static func rounded(size: CGFloat, weight: UIFont.Weight, relativeTo textStyle: UIFont.TextStyle) -> Font {
    let descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.rounded)
    let baseFont = descriptor.map { UIFont(descriptor: $0, size: size) }
        ?? UIFont.systemFont(ofSize: size, weight: weight)
    return Font(UIFontMetrics(forTextStyle: textStyle).scaledFont(for: baseFont))
    }

    static func serif(size: CGFloat, weight: UIFont.Weight, relativeTo textStyle: UIFont.TextStyle) -> Font {
        Font(scaledUIFont(uiFont(size: size, weight: weight, serif: true), relativeTo: textStyle))
    }

    static func monospaced(size: CGFloat, weight: UIFont.Weight = .regular, relativeTo textStyle: UIFont.TextStyle) -> Font {
        let baseFont = UIFont.monospacedSystemFont(ofSize: size, weight: weight)
        return Font(UIFontMetrics(forTextStyle: textStyle).scaledFont(for: baseFont))
    }
}

enum MyChatResponseTypesetting {
    private static let punctuation = CharacterSet(charactersIn: "，。！？：；、（）《》〈〉【】〔〕「」『』")
    private static let contextualQuotes = CharacterSet(charactersIn: "“”‘’")
    private static let closingPunctuation = CharacterSet(charactersIn: "，。！？：；、）》〉】〕」』”’")
    private static let closingAdjustments: [UInt32: Double] = {
        let font = MyChatSystemFont.hanUIFont(size: 17)
        return Dictionary(uniqueKeysWithValues: "，。！？：；、）》〉】〕」』”’".unicodeScalars.map { scalar in
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: String(scalar), attributes: [.font: font]) as CFAttributedString
            )
            // Already proportional quotes retain their native width. Only
            // full-width punctuation is tightened; its advance stays positive.
            return (scalar.value, min(0, 8.5 - CTLineGetTypographicBounds(line, nil, nil, nil)))
        })
    }()

    private static func isHan(_ scalar: UnicodeScalar) -> Bool {
        (0x3400...0x9FFF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
            || (0x20000...0x323AF).contains(scalar.value)
    }

    static func response(_ input: AttributedString, scale: CGFloat = 1) -> AttributedString {
        var output = input
        let bodySize = MyChatTypography.responseBodySize * scale
        let hanSize = MyChatTypography.responseHanSize * scale
        let bodyHan = MyChatSystemFont.hanFont(size: hanSize)
        let strongHan = MyChatSystemFont.hanFont(size: hanSize, strong: true)
        for run in input.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                let size = 16 * scale
                output[run.range].font = MyChatSystemFont.monospaced(
                    size: size,
                    weight: run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true ? .semibold : .regular,
                    relativeTo: .body
                )
                output[run.range].foregroundColor = MyChatTheme.inlineCodeText
                continue
            }
            let strong = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            let italic = run.inlinePresentationIntent?.contains(.emphasized) == true
            if strong || italic {
                let font = MyChatSystemFont.uiFont(size: bodySize, weight: strong ? .bold : .regular,
                                                  serif: true, italic: italic)
                output[run.range].font = Font(MyChatSystemFont.scaledUIFont(font, relativeTo: .body))
            }
            let font = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true ? strongHan : bodyHan
            let hasHan = input.characters[run.range].contains { $0.unicodeScalars.contains(where: isHan) }
            var hanStart: AttributedString.Index?
            for index in input.characters[run.range].indices {
                let character = input.characters[index]
                let scalars = character.unicodeScalars
                let han = scalars.contains { scalar in
                    isHan(scalar) || punctuation.contains(scalar)
                        || (hasHan && contextualQuotes.contains(scalar))
                }
                if han {
                    if hanStart == nil { hanStart = index }
                } else if let start = hanStart {
                    output[start..<index].font = font
                    output[start..<index].kern = MyChatTypography.responseHanTracking * scale
                    hanStart = nil
                }
                if han, let closing = scalars.first(where: closingPunctuation.contains) {
                    let next = input.characters.index(after: index)
                    // SwiftUI discards a cascade font's punctuation features.
                    // Explicit advance adjustment survives Text layout and is
                    // cached with the rich text; the message/copy source stays intact.
                    output[index..<next].kern = (closingAdjustments[closing.value] ?? 0) * scale
                }
            }
            if let start = hanStart {
                output[start..<run.range.upperBound].font = font
                output[start..<run.range.upperBound].kern = MyChatTypography.responseHanTracking * scale
            }
        }
        return output
    }
}

extension Color {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    fileprivate convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// A soft layered lift (contact + ambient shadow) shared by floating surfaces.
/// Depth comes from shadows and a uniform hairline — never a directional
/// white-to-black gradient stroke.
struct MyChatFloatingLift: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.40 : 0.10), radius: 1.4, y: 1)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.26 : 0.06), radius: 7, y: 3)
    }
}

extension View {
    func myChatFloatingLift() -> some View { modifier(MyChatFloatingLift()) }
}

/// The empty-state brand mark: a twelve-ray starburst with alternating ray
/// lengths so it reads organic rather than like a loading spinner.
struct MyChatStarburst: Shape {
    var rays = 12

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let count = max(rays, 2)
        for index in 0..<count {
            let angle = CGFloat(index) / CGFloat(count) * 2 * .pi - .pi / 2
            let direction = CGVector(dx: cos(angle), dy: sin(angle))
            let perpendicular = CGVector(dx: -direction.dy, dy: direction.dx)
            let length = radius * (index.isMultiple(of: 2) ? 1.0 : 0.76)
            let inner = radius * 0.14
            let halfWidth = radius * 0.145
            let tip = CGPoint(x: center.x + direction.dx * length,
                              y: center.y + direction.dy * length)
            let baseLeft = CGPoint(x: center.x + direction.dx * inner + perpendicular.dx * halfWidth,
                                   y: center.y + direction.dy * inner + perpendicular.dy * halfWidth)
            let baseRight = CGPoint(x: center.x + direction.dx * inner - perpendicular.dx * halfWidth,
                                    y: center.y + direction.dy * inner - perpendicular.dy * halfWidth)
            var ray = Path()
            ray.move(to: baseLeft)
            ray.addLine(to: tip)
            ray.addLine(to: baseRight)
            ray.closeSubpath()
            path.addPath(ray)
        }
        return path
    }
}

/// The floating-control bubble. On iOS 26+ this is the system's own Liquid
/// Glass — the exact surface the navigation bar renders for its toolbar
/// buttons — so the header and composer bubbles are identical to the settings
/// sheet's toolbar circles. Never add a stroke, hairline, or underlay fill:
/// any extra frame reads as a border and breaks the match.
struct MyChatFloatingSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var isInteractive = false

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(Color(UIColor.secondarySystemFill), in: shape)
        }
    }
}

struct MyChatIconButtonStyle: ButtonStyle {
    var size: CGFloat = MyChatTheme.controlSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .modifier(MyChatFloatingSurface(shape: Circle(), isInteractive: true))
            .modifier(MyChatBubblePressFeedback(isPressed: configuration.isPressed, glassOwnsFeedback: true))
    }
}

struct MyChatBubblePressStyle: ButtonStyle {
    var glassSurface = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(MyChatBubblePressFeedback(isPressed: configuration.isPressed, glassOwnsFeedback: glassSurface))
    }
}

/// Press feedback shared by the floating bubbles. On iOS 26+ the interactive
/// glass already supplies the native highlight, so only a gentle squish is
/// layered on top — an opacity fade dims the glass and breaks the native feel.
struct MyChatBubblePressFeedback: ViewModifier {
    let isPressed: Bool
    var glassOwnsFeedback: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(isPressed ? 0.72 : 1.0)
        } else if #available(iOS 26.0, *), glassOwnsFeedback {
            content
                .scaleEffect(isPressed ? 0.95 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isPressed)
        } else {
            content
                .opacity(isPressed ? 0.6 : 1.0)
                .scaleEffect(isPressed ? 0.94 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isPressed)
        }
    }
}

@MainActor
enum HapticFeedback {
    /// These are MyChat's interaction semantics, not inferred Claude waveforms.
    enum Event { case surface, selection, send, stop, success, error }
    enum Pattern: Equatable {
        case selection
        case impact(UIImpactFeedbackGenerator.FeedbackStyle, CGFloat)
        case notification(UINotificationFeedbackGenerator.FeedbackType)
    }
    static let preferenceKey = "mychat.interaction.hapticsEnabled"
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()
    static let intensity: Float = 0.9

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    }

    static func pattern(for event: Event, enabled: Bool, reduceMotion: Bool) -> Pattern? {
        guard enabled else { return nil }
        func strength(_ value: CGFloat) -> CGFloat { reduceMotion ? min(value, 0.45) : value }
        switch event {
        case .surface: return .impact(.soft, strength(CGFloat(intensity)))
        case .selection: return .selection
        case .send: return .impact(.medium, strength(0.65))
        case .stop: return .impact(.rigid, strength(0.55))
        case .success: return .notification(.success)
        case .error: return .notification(.error)
        }
    }

    static func prepare() {
        if isEnabled { soft.prepare() }
    }

    static func impact() {
        play(.surface)
    }

    static func play(_ event: Event) {
        guard let pattern = pattern(for: event, enabled: isEnabled,
                                    reduceMotion: UIAccessibility.isReduceMotionEnabled) else { return }
        // UIKit handles hardware capability and system haptic policy. No custom
        // engine, timers, token callbacks or animation-frame feedback is used.
        switch pattern {
        case .selection:
            selection.selectionChanged(); selection.prepare()
        case let .impact(style, strength):
            let generator = style == .medium ? medium : style == .rigid ? rigid : soft
            generator.impactOccurred(intensity: strength); generator.prepare()
        case let .notification(type):
            notification.notificationOccurred(type); notification.prepare()
        }
    }
}

#if DEBUG
/// Timestamped stdout diagnostics plus a main-thread hang monitor. The hang
/// monitor pings the main queue from a background thread every 250 ms; a
/// >1 s silence is printed so device console captures can be correlated
/// with tap logs when the UI stops responding.
enum MyChatDebugLog {
    private static let started = { startMonitor(); return true }()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func event(_ message: String) {
        _ = started
        print("[\(formatter.string(from: Date()))] [MyChatDebug] \(message)")
    }

    private static func startMonitor() {
        let thread = Thread {
            let semaphore = DispatchSemaphore(value: 0)
            var hungRounds = 0
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                DispatchQueue.main.async { semaphore.signal() }
                if semaphore.wait(timeout: .now() + 1.0) == .timedOut {
                    hungRounds += 1
                    print("[\(Date())] [MyChatDebug] MAIN THREAD HUNG (round \(hungRounds))")
                } else if hungRounds > 0 {
                    print("[\(Date())] [MyChatDebug] main thread recovered after \(hungRounds) hung round(s)")
                    hungRounds = 0
                }
            }
        }
        thread.name = "MyChatHangMonitor"
        thread.stackSize = 1 << 18
        thread.start()
    }
}
#else
enum MyChatDebugLog {
    @inline(__always) static func event(_ message: @autoclosure () -> String) {}
}
#endif

/// The same stacked tray glyph is used for every project entry.
struct MyChatProjectGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 7, y: 3)); p.addLine(to: CGPoint(x: 17, y: 3))
        p.move(to: CGPoint(x: 5, y: 7)); p.addLine(to: CGPoint(x: 19, y: 7))
        p.move(to: CGPoint(x: 4, y: 11))
        p.addQuadCurve(to: CGPoint(x: 2.8, y: 12.4), control: CGPoint(x: 2.6, y: 11))
        p.addLine(to: CGPoint(x: 4.5, y: 21))
        p.addQuadCurve(to: CGPoint(x: 6, y: 22), control: CGPoint(x: 4.7, y: 22))
        p.addLine(to: CGPoint(x: 18, y: 22))
        p.addQuadCurve(to: CGPoint(x: 19.5, y: 21), control: CGPoint(x: 19.3, y: 22))
        p.addLine(to: CGPoint(x: 21.2, y: 12.4))
        p.addQuadCurve(to: CGPoint(x: 20, y: 11), control: CGPoint(x: 21.4, y: 11))
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}
struct MyChatProjectIcon: View {
    // Native menus extract an Image; arbitrary Shape views are not bridged.
    @MainActor static let menuImage: UIImage = {
        let size = CGSize(width: 24, height: 24)
        return UIGraphicsImageRenderer(size: size).image { renderer in
            let context = renderer.cgContext
            context.setStrokeColor(UIColor.black.cgColor)
            context.setLineWidth(24 / 15)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(MyChatProjectGlyph().path(in: CGRect(origin: .zero, size: size)).cgPath)
            context.strokePath()
        }.withRenderingMode(.alwaysTemplate)
    }()
    var size: CGFloat = 22
    var body: some View {
        MyChatProjectGlyph().stroke(style: StrokeStyle(lineWidth: size / 15, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}
