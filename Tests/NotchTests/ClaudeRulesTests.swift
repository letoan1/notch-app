import XCTest
@testable import Notch

/// Chọn "Luôn cho phép" từ permission_suggestions và gỡ luật khỏi file settings.
final class AllowScopeTests: XCTestCase {
    private let project = "/tmp/project"

    private func rules(_ pairs: [(String, String?)], destination: String = "localSettings",
                       behavior: String = "allow") -> [String: Any] {
        ["type": "addRules", "destination": destination, "behavior": behavior,
         "rules": pairs.map { tool, content -> [String: Any] in
             var r: [String: Any] = ["toolName": tool]
             if let content { r["ruleContent"] = content }
             return r
         }]
    }

    func testRuleString() {
        XCTAssertEqual(AllowScope.ruleString(["toolName": "Bash", "ruleContent": "npm test:*"]), "Bash(npm test:*)")
        XCTAssertEqual(AllowScope.ruleString(["toolName": "mcp__github__get_issue"]), "mcp__github__get_issue")
        XCTAssertEqual(AllowScope.ruleString(["toolName": "Read", "ruleContent": ""]), "Read")
        XCTAssertNil(AllowScope.ruleString(["ruleContent": "x"]))
        XCTAssertNil(AllowScope.ruleString(["toolName": ""]))
    }

    func testAddRulesAccepted() throws {
        let scope = try XCTUnwrap(AllowScope(entry: rules([("Bash", "npm test:*")]), projectDir: project))
        XCTAssertEqual(scope.rules, ["Bash(npm test:*)"])
        XCTAssertEqual(scope.fileURL?.path, "/tmp/project/.claude/settings.local.json")
        XCTAssertFalse(scope.isSession)
    }

    func testRejectsDenyRulesAndUnreadableRules() {
        XCTAssertNil(AllowScope(entry: rules([("Bash", "rm:*")], behavior: "deny"), projectDir: project))
        var broken = rules([("Bash", "ls")])
        broken["rules"] = [["toolName": "Bash", "ruleContent": "ls"], ["ruleContent": "no tool"]]
        XCTAssertNil(AllowScope(entry: broken, projectDir: project))
        XCTAssertNil(AllowScope(entry: rules([]), projectDir: project))
    }

    func testRejectsUnknownTypeOrDestination() {
        XCTAssertNil(AllowScope(entry: ["type": "addRules", "destination": "cloud", "behavior": "allow",
                                        "rules": [["toolName": "Bash"]]], projectDir: project))
        XCTAssertNil(AllowScope(entry: ["type": "removeRules", "destination": "session"], projectDir: project))
    }

    func testSetModeOnlyForSessionAndNeverBypass() {
        XCTAssertNotNil(AllowScope(entry: ["type": "setMode", "destination": "session", "mode": "acceptEdits"], projectDir: project))
        XCTAssertNil(AllowScope(entry: ["type": "setMode", "destination": "userSettings", "mode": "acceptEdits"], projectDir: project))
        XCTAssertNil(AllowScope(entry: ["type": "setMode", "destination": "session", "mode": "bypassPermissions"], projectDir: project))
    }

    func testAddDirectoriesOnlyForSession() {
        XCTAssertNotNil(AllowScope(entry: ["type": "addDirectories", "destination": "session", "directories": ["/tmp/x"]], projectDir: project))
        XCTAssertNil(AllowScope(entry: ["type": "addDirectories", "destination": "localSettings", "directories": ["/tmp/x"]], projectDir: project))
        XCTAssertNil(AllowScope(entry: ["type": "addDirectories", "destination": "session", "directories": []], projectDir: project))
    }

    func testNarrowestPrefersSpecificRuleThenFewerRulesThenNarrowerPlace() throws {
        let suggestions: [Any] = [
            ["type": "setMode", "destination": "session", "mode": "acceptEdits"],
            rules([("Bash", nil)], destination: "session"),
            rules([("Bash", "git status"), ("Bash", "git diff")], destination: "session"),
            rules([("Bash", "git status")], destination: "userSettings"),
            rules([("Bash", "git status")], destination: "localSettings"),
            "not a dictionary",
        ]
        let best = try XCTUnwrap(AllowScope.narrowest(suggestions, projectDir: project))
        XCTAssertEqual(best.rules, ["Bash(git status)"])
        XCTAssertEqual(best.destination, .localSettings)
    }

    func testNarrowestFallsBackToDirectoriesThenMode() throws {
        let mode: [String: Any] = ["type": "setMode", "destination": "session", "mode": "acceptEdits"]
        let dirs: [String: Any] = ["type": "addDirectories", "destination": "session", "directories": ["/tmp/x"]]
        XCTAssertEqual(try XCTUnwrap(AllowScope.narrowest([mode, dirs], projectDir: project)).type, "addDirectories")
        XCTAssertEqual(try XCTUnwrap(AllowScope.narrowest([mode], projectDir: project)).type, "setMode")
        XCTAssertNil(AllowScope.narrowest(nil, projectDir: project))
        XCTAssertNil(AllowScope.narrowest([], projectDir: project))
    }
}

final class ClaudeRulesFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("roost-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String) throws -> URL {
        let url = dir.appendingPathComponent("settings.json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testAllowList() throws {
        let url = try write(#"{"permissions":{"allow":["Read","Bash(ls)"]}}"#)
        XCTAssertEqual(ClaudeRulesFile.allowList(url), ["Read", "Bash(ls)"])
        XCTAssertEqual(ClaudeRulesFile.allowList(dir.appendingPathComponent("missing.json")), [])
    }

    func testRevokeEditsInPlaceAndKeepsFormatting() throws {
        let original = """
        {
          "model": "opus",
          "permissions": {
            "allow": [
              "Read",
              "Bash(npm test:*)",
              "WebFetch(domain:example.com)"
            ]
          }
        }
        """
        let url = try write(original)
        let backup = try ClaudeRulesFile.revoke(rule: "Bash(npm test:*)", in: url)
        let edited = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(edited, """
        {
          "model": "opus",
          "permissions": {
            "allow": [
              "Read",
              "WebFetch(domain:example.com)"
            ]
          }
        }
        """)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("settings.json.bak-roost-"))
    }

    func testRevokeLastAndOnlyRule() throws {
        let url = try write(#"{"permissions":{"allow":[ "Read" ],"deny":["Bash(rm:*)"]}}"#)
        try ClaudeRulesFile.revoke(rule: "Read", in: url)
        XCTAssertEqual(ClaudeRulesFile.allowList(url), [])
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual((root?["permissions"] as? [String: Any])?["deny"] as? [String], ["Bash(rm:*)"])
    }

    func testRevokeRuleWithSlashes() throws {
        let url = try write(#"{"permissions":{"allow":["Read(/tmp/**)","Edit"]}}"#)
        try ClaudeRulesFile.revoke(rule: "Read(/tmp/**)", in: url)
        XCTAssertEqual(ClaudeRulesFile.allowList(url), ["Edit"])
    }

    func testRevokeMissingRuleThrowsAndLeavesFileAlone() throws {
        let text = #"{"permissions":{"allow":["Read"]}}"#
        let url = try write(text)
        XCTAssertThrowsError(try ClaudeRulesFile.revoke(rule: "Edit", in: url)) { error in
            guard case ClaudeRulesFile.RevokeError.notFound = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }

    func testRevokeUnreadableFileThrows() throws {
        let url = try write("not json")
        XCTAssertThrowsError(try ClaudeRulesFile.revoke(rule: "Read", in: url)) { error in
            guard case ClaudeRulesFile.RevokeError.unreadable = error else { return XCTFail("\(error)") }
        }
    }
}
