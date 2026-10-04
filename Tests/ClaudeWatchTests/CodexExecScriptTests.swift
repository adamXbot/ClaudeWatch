import XCTest
@testable import ClaudeWatchCore

/// Reading the calls out of a Codex "code mode" script without running it.
final class CodexExecScriptTests: XCTestCase {

    private typealias Call = CodexExecScript.Call

    func testCallsComeInTheOrderWritten() {
        let calls = CodexExecScript.calls(in: #"""
            const a = await tools.exec_command({cmd:"one"});
            const b = await tools["view_image"]({path:"/tmp/a.png"});
            text(await tools.apply_patch("two"));
            await tools . write_stdin ( { session_id : 12 , chars : "three" } );
            other.tools.exec_command({cmd:"not the tools object"});
            const run = tools.exec_command;
            """#)
        XCTAssertEqual(calls, [
            Call(tool: "exec_command", properties: ["cmd": .known("one")]),
            Call(tool: "view_image", properties: ["path": .known("/tmp/a.png")]),
            Call(tool: "apply_patch", argument: .known("two")),
            Call(tool: "write_stdin", properties: ["session_id": .known("12"), "chars": .known("three")]),
        ])
    }

    func testCallInsideAnArgumentIsFound() {
        let calls = CodexExecScript.calls(in: #"""
            text(await tools.apply_patch((await tools.exec_command({cmd:"make-patch"})).output));
            """#)
        XCTAssertEqual(calls, [
            Call(tool: "apply_patch", argument: .computed),
            Call(tool: "exec_command", properties: ["cmd": .known("make-patch")]),
        ])
    }

    func testOnlyAWholeLiteralIsKnown() {
        let calls = CodexExecScript.calls(in: #"""
            tools.exec_command({cmd: "a" + suffix, workdir: dir.trim(), tty: true, ...rest, [key]: 1, "max_output_tokens": 2000});
            tools.exec_command({...base, cmd});
            tools.exec_command();
            """#)
        XCTAssertEqual(calls, [
            Call(tool: "exec_command", properties: [
                "cmd": .computed, "workdir": .computed, "tty": .computed, "max_output_tokens": .known("2000"),
            ]),
            Call(tool: "exec_command", properties: ["cmd": .computed]),
            Call(tool: "exec_command"),
        ])
    }

    private func command(_ script: String) -> CodexExecScript.Argument? {
        CodexExecScript.calls(in: script).last?.properties["cmd"]
    }

    func testANameStandsForItsLiteralOnlyWhileThatIsCertain() {
        // Declared once, with a literal.
        XCTAssertEqual(command(#"const cmd = "a"; tools.exec_command({cmd});"#), .known("a"))
        XCTAssertEqual(command(#"const c = 'a'; tools.exec_command({cmd: c});"#), .known("a"))
        XCTAssertEqual(command("let cmd = `a`\ntools.exec_command({cmd})"), .known("a"))
        XCTAssertEqual(command(#"const x = "a", cmd = x; tools.exec_command({cmd});"#), .known("a"))
        XCTAssertEqual(command(#"const cmd = "a"; tools.exec_command({cmd}); list.map(cmd => 1);"#), .known("a"),
                       "a later parameter of the same name is another scope")

        // Not a literal, or more than a literal.
        XCTAssertEqual(command(#"const cmd = build(); tools.exec_command({cmd});"#), .computed)
        XCTAssertEqual(command(#"const cmd = "a" + b; tools.exec_command({cmd});"#), .computed)
        XCTAssertEqual(command("const cmd = \"a\"\n  .trim(); tools.exec_command({cmd});"), .computed)

        // Assigned to afterwards.
        XCTAssertEqual(command(#"let cmd = "a"; cmd = "b"; tools.exec_command({cmd});"#), .computed)
        XCTAssertEqual(command(#"let cmd = "a"; cmd += " b"; tools.exec_command({cmd});"#), .computed)
        XCTAssertEqual(command(#"let cmd = "a"; if (cmd === "a") tools.exec_command({cmd});"#), .known("a"), "a comparison is not an assignment")

        // Hidden by another declaration of the same name.
        XCTAssertEqual(command(#"const cmd = "a"; for (const cmd of list) tools.exec_command({cmd});"#), .computed)
        XCTAssertEqual(command(#"const cmd = "a"; for (const [name, cmd] of list) tools.exec_command({cmd});"#), .computed)
        XCTAssertEqual(command(#"const cmd = "a"; list.map(cmd => tools.exec_command({cmd}));"#), .computed)
        XCTAssertEqual(command(#"const cmd = "a"; list.map(async (name, cmd) => tools.exec_command({cmd}));"#), .computed)
        XCTAssertEqual(command(#"const cmd = "a"; function run(cmd) { return tools.exec_command({cmd}); }"#), .computed)
        XCTAssertEqual(command(#"const cmd = "a"; { const cmd = "b"; tools.exec_command({cmd}); }"#), .computed)
    }

    func testEscapes() {
        func text(_ literal: String) -> String? { command("tools.exec_command({cmd: \(literal)})")?.text }
        XCTAssertEqual(text(#""tab\there\r\n""#), "tab\there\r\n")
        XCTAssertEqual(text(#""\x41\u0042\u{43}\u{1F600}""#), "ABC\u{1F600}")
        XCTAssertEqual(text(#""\uD83D\uDE00 \uD83D alone""#), "\u{1F600} \u{FFFD} alone")
        XCTAssertEqual(text(#"'it\'s \"quoted\" \\ \/ \q'"#), #"it's "quoted" \ / q"#)
        XCTAssertEqual(text("\"one \\\ntwo\""), "one two", "a backslash at the end of a line continues it")
        XCTAssertEqual(text(#"`a \` b \${c} ${d}`"#), "a ` b ${c} ${d}")
        XCTAssertEqual(text(#"String.raw`a\nb`"#), #"a\nb"#)
        XCTAssertEqual(text(#""caf\#u{E9} 日本語""#), "caf\u{E9} 日本語")
    }

    func testRegularExpressionsAndDivisionAreToldApart() {
        // A quote inside a regular expression must not open a string.
        XCTAssertEqual(command(#"const ok = /["']/.test(s); tools.exec_command({cmd:"a"});"#), .known("a"))
        XCTAssertEqual(command(#"const parts = s.split(/[/"]+/g); tools.exec_command({cmd:"a"});"#), .known("a"))
        // A division is not the start of one.
        XCTAssertEqual(command(#"const half = total / 2; const s = "x/"; tools.exec_command({cmd:"a"});"#), .known("a"))
        XCTAssertEqual(command(#"const r = (a + b) / c / d; tools.exec_command({cmd:"a"}); // "#), .known("a"))
    }

    func testBrokenScriptsAreReadAsFarAsTheyGo() {
        for script in [
            "", "tools", "tools.", "tools.exec_command", "tools.exec_command(", "tools.exec_command({", "tools.exec_command({cmd",
            "tools.exec_command({cmd:", #"tools.exec_command({cmd:"unterminated"#, "tools.exec_command({cmd:`unterminated ${",
            #"tools.exec_command({cmd:"trailing\"#, "const", "const [", "const x =", "function (", "/", "/*", "`${`${`${",
            #"tools["exec_command""#, "tools.apply_patch(String.raw", ")=>", "}}}})))", #""\u{""#, #""\u12""#, #""\x""#,
        ] {
            _ = CodexExecScript.calls(in: script)       // must return, whatever it returns
        }
        XCTAssertEqual(CodexExecScript.calls(in: #"tools.exec_command({cmd:"unterminated"#).map(\.tool), ["exec_command"])

        // Thousands of nested templates must not run out of stack.
        let nested = String(repeating: "`${", count: 20_000)
        XCTAssertEqual(CodexExecScript.calls(in: "tools.exec_command({cmd:\"a\"}); " + nested).map(\.tool), ["exec_command"])
    }
}
