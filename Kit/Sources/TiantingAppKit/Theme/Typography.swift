import SwiftUI

/// PRD-ui 6.3 font tokens mapped to the nearest Dynamic Type style (PRD-ui 3.5 rule 1): 12 caption, 14 subheadline-sized
/// footnote, 16 body, 17 headline, 22 title2. Text scales up to accessibility3.
public enum TTFont {
    public static let caption = Font.caption
    public static let small = Font.subheadline
    public static let body = Font.body
    public static let title = Font.headline
    public static let large = Font.title2
}

public typealias TC = Tokens.Palette
public typealias TS = Tokens.Space
public typealias TR = Tokens.Radius
