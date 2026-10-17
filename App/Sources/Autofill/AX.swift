import AppKit
import ApplicationServices

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

    static func hint(_ el: AXUIElement) -> String {
        [kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXIdentifierAttribute, kAXHelpAttribute, "AXDOMIdentifier"]
            .compactMap { string(el, $0) }.joined(separator: " ").lowercased()
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
