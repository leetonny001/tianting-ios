import Foundation

/// The emoji panel (PRD-ui F-UI-11): common system emoji, single code points within Unicode 13.0 (no ZWJ sequences or
/// variation selectors), sent as plain text and drawn with the system font. Same list as tianting-web.
public let emojiList: [String] = "😀😃😄😁😆😅😂🤣😊😇🙂🙃😉😌😍🥰😘😗😙😚😋😛😝😜🤪🤨🧐🤓😎🤩🥳😏😒😞😔😟😕🙁😣😖😫😩🥺😢😭😤😠😡🤬🤯😳🥵🥶😱😨😰😥😓🤗🤔🤭🤫🤥😶😐😑😬🙄😯😦😧😮😲🥱😴🤤😪😵🤐🥴🤢🤮🤧😷🤒🤕👍👎👌👏🙏🤝💪👋🎉🎂🌹🌈🔥💯💖💔⭐🍻☕🍉"
    .map(String.init)

/// Replaces the UTF-16 range `range` with `insert`; returns the new text and where the caret goes (AC-UI-11-1).
public func insertText(_ insert: String, into text: String, range: NSRange) -> (text: String, caret: NSRange) {
    let ns = text as NSString
    let safe = NSRange(location: min(range.location, ns.length), length: min(range.length, ns.length - min(range.location, ns.length)))
    let next = ns.replacingCharacters(in: safe, with: insert)
    return (next, NSRange(location: safe.location + (insert as NSString).length, length: 0))
}
