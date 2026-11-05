import Foundation
import TiantingIM

// Contact-list grouping (PRD-ui F-UI-13 rule 4). The letter comes from the SDK's `pinyinGroup` (vectors/pinyin-groups.json).

private func startsWithHan(_ s: String) -> Bool {
    s.unicodeScalars.first?.properties.isIdeographic ?? false
}

private func pinyinKey(_ s: String) -> String {
    let m = NSMutableString(string: s)
    CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
    CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
    return (m as String).lowercased()
}

private func byteLess(_ a: String, _ b: String) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
}

/// Orders display names by pinyin; names not starting with Han come first ("Alpha" before "周末球局", AC-UI-32-1).
public func nameLess(_ a: String, _ b: String) -> Bool {
    let (ha, hb) = (startsWithHan(a), startsWithHan(b))
    if ha != hb { return hb }
    let (ka, kb) = (pinyinKey(a), pinyinKey(b))
    return ka != kb ? ka < kb : a < b
}

public struct PinyinSection<T> {
    public let letter: String
    public let items: [T]
}

/// A...Z then "#"; within a section by name, then id bytes.
public func groupByPinyin<T>(_ items: [T], name: (T) -> String, id: (T) -> String) -> [PinyinSection<T>] {
    var groups: [String: [T]] = [:]
    for x in items { groups[pinyinGroup(name(x)), default: []].append(x) }
    return groups.keys.sorted { a, b in
        if a == "#" { return false }
        if b == "#" { return true }
        return a < b
    }.map { letter in
        PinyinSection(
            letter: letter,
            items: groups[letter]!.sorted { x, y in
                let (nx, ny) = (name(x), name(y))
                return nx == ny ? byteLess(id(x), id(y)) : nameLess(nx, ny)
            })
    }
}
