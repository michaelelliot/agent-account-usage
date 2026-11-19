import Foundation
import Testing

@testable import SubSmasherCore

struct ConfigTests {
    @Test func readsSectionsAndTrimmedPairs() {
        let profiles = ConfigFile.parse("[default]\nclaude_config_dir = ~/.claude\n\n[ work ]\noauth_token=sk-ant-oat01-abc\n")
        #expect(profiles.map(\.id) == ["default", "work"])
        #expect(profiles[0].values == ["claude_config_dir": "~/.claude"])
        #expect(profiles[1].values == ["oauth_token": "sk-ant-oat01-abc"])
    }

    @Test func skipsCommentsBlankLinesPairlessLinesAndOrphanKeys() {
        let profiles = ConfigFile.parse(
            "orphan = 1\n# comment\n; also comment\n[default]\n  # indented comment\nnot a pair\nkey = value\n")
        #expect(profiles == [Profile(id: "default", values: ["key": "value"])])
    }

    @Test func keepsEqualsInValuesAndHandlesCRLF() {
        #expect(ConfigFile.parse("[default]\r\ntoken = a=b==\r\n").first?.values == ["token": "a=b=="])
    }

    @Test func mergesRepeatedSectionsLaterKeysWin() {
        let profiles = ConfigFile.parse("[a]\nx = 1\ny = 2\n[b]\n[a]\nx = 3\n")
        #expect(profiles.map(\.id) == ["a", "b"])
        #expect(profiles[0].values == ["x": "3", "y": "2"])
    }

    @Test func stripsOnePairOfMatchingQuotes() {
        let values = ConfigFile.parse(
            "[default]\na = \"me@example.com\"\nb = 'single'\nc = \"mismatched'\nd = \"\"\ne = say \"hi\"\n").first?.values
        #expect(values == ["a": "me@example.com", "b": "single", "c": "\"mismatched'", "d": "", "e": "say \"hi\""])
    }

    @Test func displayNameFallsBackToSectionId() {
        #expect(Profile(id: "work", values: ["name": "Work"]).displayName == "Work")
        #expect(Profile(id: "work", values: ["name": ""]).displayName == "work")
        #expect(Profile(id: "work").displayName == "work")
    }

    @Test func defaultsToSubsmasherConfigUnlessOnlyTheAgentUsageOneExists() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "subsmash-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: ".config/subsmasher/config")
        let legacy = home.appending(path: ".config/agent-usage/config")
        func create(_ file: URL) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        #expect(ConfigFile.defaultURL(home: home) == url)
        try create(legacy)
        #expect(ConfigFile.defaultURL(home: home) == legacy)
        try create(url)
        #expect(ConfigFile.defaultURL(home: home) == url)
    }

    @Test func expandsLeadingTildeOnly() {
        #expect(expandHome("~") == NSHomeDirectory())
        #expect(expandHome("~/.claude") == NSHomeDirectory() + "/.claude")
        #expect(expandHome("/tmp/~x") == "/tmp/~x")
        #expect(expandHome("~other/x") == "~other/x")
    }
}
