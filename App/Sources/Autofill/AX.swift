import AppKit
@preconcurrency import ApplicationServices
import SwiftwardenCore

enum AX {
    static func raw(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = raw(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? { raw(el, name) as? String }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        guard let v = raw(el, kAXChildrenAttribute), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (v as! [AnyObject]).compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    static func url(_ el: AXUIElement) -> String? {
        guard let v = raw(el, "AXURL") else { return nil }
        if CFGetTypeID(v) == CFURLGetTypeID() { return (v as! URL).absoluteString }
        return v as? String
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = raw(el, kAXPositionAttribute), let s = raw(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: pt.x, y: h - pt.y - sz.height, width: sz.width, height: sz.height)
    }

    static func isSecure(_ el: AXUIElement) -> Bool { string(el, kAXSubroleAttribute) == kAXSecureTextFieldSubrole }

    static func isTextInput(_ el: AXUIElement) -> Bool {
        let r = string(el, kAXRoleAttribute)
        return r == kAXTextFieldRole || r == kAXComboBoxRole || r == "AXSearchField"
    }

    static func hints(_ el: AXUIElement) -> FieldHints {
        var t: [String] = []
        let current = string(el, kAXValueAttribute)?.trimmingCharacters(in: .whitespaces) ?? ""
        for a in [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute, "AXDOMIdentifier", kAXHelpAttribute] {
            if let s = string(el, a), !s.isEmpty, s.count < 120,
               current.isEmpty || s.trimmingCharacters(in: .whitespaces) != current { t.append(s) }
        }
        if let classes = raw(el, "AXDOMClassList") as? [String] { t += classes.prefix(6) }
        if let label = element(el, kAXTitleUIElementAttribute) {
            t += [string(label, kAXValueAttribute), string(label, kAXTitleAttribute), string(label, kAXDescriptionAttribute)].compactMap { $0 }
        }
        if let parent = element(el, kAXParentAttribute) {
            let kids = children(parent)
            if let i = kids.firstIndex(where: { CFEqual($0, el) }) {
                for sib in kids[..<i].reversed().prefix(3) {
                    if isTextInput(sib) || isSecure(sib) { break }
                    if string(sib, kAXRoleAttribute) == kAXStaticTextRole, let s = string(sib, kAXValueAttribute) ?? string(sib, kAXTitleAttribute),
                       !s.isEmpty, s.count < 60 {
                        t.append(s)
                        break
                    }
                }
            }
        }
        return FieldHints(texts: t, autocomplete: string(el, "AXAutocompleteValue"), isSecure: isSecure(el))
    }

    static func kind(_ el: AXUIElement) -> FieldKind { FieldClassifier.classify(hints(el)) }

    static let searchWords = ["search", "suche", "suchen", "address and search", "adress- und suchleiste", "omnibox", "location bar",
                              "url bar", "address bar", "adressleiste", "search or enter", "suchbegriff oder adresse"]

    static func isSearch(_ el: AXUIElement) -> Bool {
        if string(el, kAXRoleAttribute) == "AXSearchField" || string(el, kAXSubroleAttribute) == kAXSearchFieldSubrole { return true }
        let type = (string(el, "AXDOMInputType") ?? string(el, "AXInputType") ?? "").lowercased()
        if type == "search" || type == "url" { return true }
        let ident = [string(el, kAXIdentifierAttribute), string(el, "AXDOMIdentifier")].compactMap { $0?.lowercased() }.joined(separator: " ")
        if ident.contains("address_and_search") || ident.contains("urlbar") || ident.contains("omnibox") || ident.contains("search") { return true }
        let own = [kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute]
            .compactMap { string(el, $0)?.lowercased() }.joined(separator: " ")
        return searchWords.contains { w in
            own.range(of: "(^|[^\\p{L}])" + NSRegularExpression.escapedPattern(for: w) + "($|[^\\p{L}])", options: .regularExpression) != nil
        }
    }

    static func webArea(of el: AXUIElement) -> AXUIElement? {
        var cur: AXUIElement? = el
        for _ in 0 ..< 80 {
            guard let c = cur else { return nil }
            if string(c, kAXRoleAttribute) == "AXWebArea" { return c }
            cur = element(c, kAXParentAttribute)
        }
        return nil
    }

    static func sameWebArea(_ a: AXUIElement, _ area: AXUIElement?) -> Bool {
        guard let area else { return webArea(of: a) == nil }
        return webArea(of: a).map { CFEqual($0, area) } ?? false
    }

    static func nextInput(after el: AXUIElement, levels: Int = 3) -> AXUIElement? {
        var ancestor = element(el, kAXParentAttribute)
        for _ in 0 ..< levels {
            guard let a = ancestor else { return nil }
            let area = webArea(of: el)
            let inputs = collectInputs(a, limit: 200).filter { CFEqual($0, el) || sameWebArea($0, area) }
            if let i = inputs.firstIndex(where: { CFEqual($0, el) }), i + 1 < inputs.count { return inputs[i + 1] }
            ancestor = element(a, kAXParentAttribute)
        }
        return nil
    }

    static func formInputs(around el: AXUIElement, want: Int = 10) -> [AXUIElement] {
        var best: [AXUIElement] = [el]
        var ancestor = element(el, kAXParentAttribute)
        let window = element(el, kAXWindowAttribute).flatMap(rawFrame)
        let area = webArea(of: el)
        for _ in 0 ..< 7 {
            guard let a = ancestor else { break }
            let inputs = collectInputs(a, limit: 1500).filter {
                CFEqual($0, el) || (isVisible($0, in: window) && !isSearch($0) && sameWebArea($0, area))
            }
            if inputs.count > best.count { best = inputs }
            if inputs.count >= want { break }
            ancestor = element(a, kAXParentAttribute)
        }
        return best
    }

    static func rawFrame(_ el: AXUIElement) -> CGRect? {
        guard let p = raw(el, kAXPositionAttribute), let s = raw(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    static func isVisible(_ el: AXUIElement, in window: CGRect?) -> Bool {
        if (raw(el, "AXHidden") as? Bool) == true { return false }
        guard let f = rawFrame(el) else { return true }
        if f.width < 4 || f.height < 4 { return false }
        guard let w = window else { return true }
        return f.maxX > w.minX && f.minX < w.maxX && f.maxY > w.minY - 9000
    }

    static func collectInputs(_ root: AXUIElement, limit: Int = 800) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var stack = [root]
        var visited = 0
        while let el = stack.popLast(), visited < limit {
            visited += 1
            if isTextInput(el) { out.append(el); continue }
            stack.append(contentsOf: children(el).reversed())
        }
        return out
    }
}




