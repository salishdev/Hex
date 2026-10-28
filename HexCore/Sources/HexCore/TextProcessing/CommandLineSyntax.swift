import Foundation

/// Splits a one-line command into an executable and literal arguments using
/// familiar shell quoting. It only tokenizes: there is no expansion,
/// globbing, variables, pipes, or redirection, and nothing runs in a shell.
public enum CommandLineSyntax {
    public struct ParseError: LocalizedError, Equatable {
        public var errorDescription: String? { "Close the quote at the end of the command" }
    }

    /// Whitespace separates words. 'single quotes' are literal. "double quotes"
    /// honor backslash before \ and ". Outside quotes, a backslash escapes the next character.
    public static func split(_ line: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var iterator = Array(line).makeIterator()
        while let character = iterator.next() {
            switch character {
            case " ", "\t", "\n", "\r":
                if inWord { words.append(current); current = ""; inWord = false }
            case "'":
                inWord = true
                while true {
                    guard let next = iterator.next() else { throw ParseError() }
                    if next == "'" { break }
                    current.append(next)
                }
            case "\"":
                inWord = true
                while true {
                    guard let next = iterator.next() else { throw ParseError() }
                    if next == "\"" { break }
                    if next == "\\" {
                        guard let escaped = iterator.next() else { throw ParseError() }
                        if escaped != "\\" && escaped != "\"" { current.append("\\") }
                        current.append(escaped)
                    } else {
                        current.append(next)
                    }
                }
            case "\\":
                inWord = true
                if let escaped = iterator.next() { current.append(escaped) }
            default:
                inWord = true
                current.append(character)
            }
        }
        if inWord { words.append(current) }
        return words
    }

    /// The inverse of `split`: quotes only the words that need it.
    public static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }

    static func quote(_ word: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+=:,@%"))
        if !word.isEmpty && word.unicodeScalars.allSatisfy(plain.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
