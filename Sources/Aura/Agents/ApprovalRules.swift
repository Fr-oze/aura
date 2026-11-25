import Foundation

enum RuleVerdict {
    case autoAllow   // toutes les parties de la commande sont routinières
    case mustAsk     // au moins une partie est dans « toujours demander »
    case unlisted    // ni l'un ni l'autre
}

/// Règles d'auto-approbation.
///
/// Une règle est soit un préfixe (`git status` reconnaît `git status` et `git status -s`),
/// soit une expression régulière précédée de `re:` (`re:^npm run (build|lint)$`).
///
/// Une commande composée (`a && b`, `a | b`, `a ; b`) est découpée : elle n'est autorisée
/// d'office que si CHAQUE partie est routinière, et elle est toujours soumise dès qu'UNE partie
/// est dans « toujours demander ». Substitutions et redirections vers un fichier empêchent
/// l'autorisation d'office.
enum ApprovalRules {

    static func evaluate(_ command: String, autoApprove: [String], alwaysAsk: [String]) -> RuleVerdict {
        let cleaned = stripHarmlessRedirections(command)
        let parts = split(cleaned)
        guard !parts.isEmpty else { return .unlisted }

        for rule in alwaysAsk {
            if matches(rule, cleaned) || parts.contains(where: { matches(rule, $0) }) {
                return .mustAsk
            }
        }
        if hasRiskySyntax(cleaned) { return .unlisted }

        let allRoutine = parts.allSatisfy { part in
            autoApprove.contains { matches($0, part) }
        }
        return allRoutine ? .autoAllow : .unlisted
    }

    static func matches(_ rule: String, _ text: String) -> Bool {
        let pattern = rule.trimmed
        guard !pattern.isEmpty else { return false }

        if pattern.hasPrefix("re:") {
            let body = String(pattern.dropFirst(3))
            guard let regex = try? NSRegularExpression(pattern: body) else { return false }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        }
        return text == pattern || text.hasPrefix(pattern + " ")
    }

    private static func stripHarmlessRedirections(_ command: String) -> String {
        var result = command
        for token in ["2>&1", "2>/dev/null", "2> /dev/null", "&>/dev/null", "&> /dev/null", ">/dev/null", "> /dev/null"] {
            result = result.replacingOccurrences(of: token, with: " ")
        }
        return result
    }

    private static func split(_ command: String) -> [String] {
        let marker = "\u{1F}"
        var text = command
        for separator in ["&&", "||", ";", "|", "\n", "&"] {
            text = text.replacingOccurrences(of: separator, with: marker)
        }
        return text.components(separatedBy: marker)
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
    }

    private static func hasRiskySyntax(_ command: String) -> Bool {
        for token in ["$(", "`", ">", "<("] where command.contains(token) {
            return true
        }
        return false
    }
}
