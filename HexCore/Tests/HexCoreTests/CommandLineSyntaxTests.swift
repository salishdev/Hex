import Foundation
import Testing
@testable import HexCore

@Suite struct CommandLineSyntaxTests {
    @Test func splitsQuotedWordsLiterally() throws {
        #expect(try CommandLineSyntax.split("") == [])
        #expect(try CommandLineSyntax.split("  /bin/cat  ") == ["/bin/cat"])
        #expect(try CommandLineSyntax.split("/a/codex.sh --model gpt-5") == ["/a/codex.sh", "--model", "gpt-5"])
        #expect(try CommandLineSyntax.split(#"'/My Scripts/x.sh' "two words" a\ b"#) == ["/My Scripts/x.sh", "two words", "a b"])
        #expect(try CommandLineSyntax.split(#""say \"hi\" \n" '$HOME' ''"#) == [#"say "hi" \n"#, "$HOME", ""])
        #expect(throws: CommandLineSyntax.ParseError.self) { try CommandLineSyntax.split("/bin/cat 'open") }
    }
    @Test func joinRoundTrips() throws {
        let words = ["/My Scripts/x.sh", "--model", "it's", "", "🌊", "$HOME", "plain-word"]
        let line = CommandLineSyntax.join(words)
        #expect(line.hasPrefix("'/My Scripts/x.sh' --model"))
        #expect(try CommandLineSyntax.split(line) == words)
    }
    @Test func presetInstallsExecutableWrapperWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModeConfigurationStore(root: root)
        let tool = try ToolPreset.claude.install(in: store)
        #expect(tool.name == "Claude Code")
        #expect(FileManager.default.isExecutableFile(atPath: tool.executable))
        let script = try String(contentsOfFile: tool.executable, encoding: .utf8)
        #expect(script.hasPrefix("#!/bin/sh\n"))
        try Data("custom".utf8).write(to: URL(fileURLWithPath: tool.executable))
        _ = try ToolPreset.claude.install(in: store)
        #expect(try String(contentsOfFile: tool.executable, encoding: .utf8) == "custom")
    }
}
