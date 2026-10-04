import XCTest
@testable import ClaudeWatchCore

final class CodexParserTests: XCTestCase {
    private func line(_ obj: [String: Any]) -> Substring {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return Substring(String(decoding: data, as: UTF8.self))
    }

    func testExecCommandUsesSessionMetaContext() {
        var context = CodexTranscriptParser.FileContext()
        let path = "/tmp/rollout-2026-07-02T11-59-07-abc.jsonl"

        _ = CodexTranscriptParser.events(fromLine: line([
            "timestamp": "2026-07-02T01:59:07.137Z",
            "type": "session_meta",
            "payload": [
                "session_id": "codex-session",
                "cwd": "/Users/x/project",
            ],
        ]), transcriptPath: path, context: &context)

        let events = CodexTranscriptParser.events(fromLine: line([
            "timestamp": "2026-07-02T02:03:46.788Z",
            "type": "response_item",
            "payload": [
                "type": "function_call",
                "name": "exec_command",
                "call_id": "call_1",
                "arguments": "{\"cmd\":\"git status\",\"workdir\":\"/Users/x/project\"}",
                "internal_chat_message_metadata_passthrough": ["turn_id": "turn-1"],
            ],
        ]), transcriptPath: path, context: &context)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].source, .codex)
        XCTAssertEqual(events[0].kind, .shell)
        XCTAssertEqual(events[0].primary, "git status")
        XCTAssertEqual(events[0].sessionId, "codex-session")
        XCTAssertEqual(events[0].projectName, "project")
    }

    func testApplyPatchIsFileEdit() {
        var context = CodexTranscriptParser.FileContext(sessionId: "s", cwd: "/repo")
        let events = CodexTranscriptParser.events(fromLine: line([
            "timestamp": "2026-07-02T02:04:45.331Z",
            "type": "response_item",
            "payload": [
                "type": "custom_tool_call",
                "name": "apply_patch",
                "call_id": "call_patch",
                "input": "*** Begin Patch\n*** Update File: src/app.swift\n@@\n-a\n+b\n*** End Patch\n",
                "internal_chat_message_metadata_passthrough": ["turn_id": "turn-1"],
            ],
        ]), transcriptPath: "/tmp/s.jsonl", context: &context)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .fileEdit)
        XCTAssertEqual(events[0].toolName, "apply_patch")
        XCTAssertEqual(events[0].primary, "src/app.swift")
        XCTAssertEqual(events[0].secondary, "1 update")
    }

    func testWriteStdinIsAShellEvent() {
        var context = CodexTranscriptParser.FileContext(sessionId: "s", cwd: "/repo")
        func stdin(_ chars: String, id: String) -> [CommandEvent] {
            CodexTranscriptParser.events(fromLine: line([
                "timestamp": "2026-07-02T02:05:00.000Z",
                "type": "response_item",
                "payload": [
                    "type": "function_call",
                    "name": "write_stdin",
                    "call_id": id,
                    "arguments": TranscriptFixtures.json(["session_id": 4, "chars": chars]),
                ],
            ]), transcriptPath: "/tmp/s.jsonl", context: &context)
        }

        let typed = stdin("y\n", id: "call_typed")
        XCTAssertEqual(typed.map(\.kind), [.shell])
        XCTAssertEqual(typed.first?.toolName, "write_stdin")
        XCTAssertEqual(typed.first?.primary, "y\\n")
        XCTAssertEqual(typed.first?.secondary, "sent to terminal 4")
        XCTAssertEqual(stdin("", id: "call_poll").map(\.primary), ["(stdin)"], "recorded on its own, a poll is still a row")
    }

    // MARK: - Code mode: an `exec` record whose input is a script

    private let scriptPath = "/Users/x/.codex/sessions/2026/10/02/rollout-2026-10-02T20-50-12-0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000.jsonl"

    /// The first record of a transcript, laid out as Codex 0.159 writes it, key for key.
    private var metaLine: Substring {
        #"{"timestamp":"2026-10-02T09:50:12.004Z","ordinal":0,"type":"session_meta","payload":{"session_id":"0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000","id":"0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000","timestamp":"2026-10-02T09:50:12.001Z","cwd":"/Users/x/project","originator":"codex_work_desktop","cli_version":"0.159.2","source":"vscode","model_provider":"openai"}}"#
    }

    /// An `exec` record in the same layout. `script` is the JavaScript Codex wrote.
    private func execLine(_ script: String, callId: String = "call_Sc1", ordinal: Int = 15) -> Substring {
        let input = String(decoding: try! JSONEncoder().encode(script), as: UTF8.self)
        return Substring(#"{"timestamp":"2026-10-02T09:50:41.299Z","ordinal":\#(ordinal),"type":"response_item","payload":{"type":"custom_tool_call","id":"ctc_0aa1","status":"completed","call_id":"\#(callId)","name":"exec","input":\#(input),"internal_chat_message_metadata_passthrough":{"turn_id":"0199aaaa-1111-7222-8333-444455556666","create_time":1790934637.201245}}}"#)
    }

    private func scriptEvents(_ script: String, callId: String = "call_Sc1") -> [CommandEvent] {
        var context = CodexTranscriptParser.FileContext()
        _ = CodexTranscriptParser.events(fromLine: metaLine, transcriptPath: scriptPath, context: &context)
        return CodexTranscriptParser.events(fromLine: execLine(script, callId: callId), transcriptPath: scriptPath, context: &context)
    }

    func testExecScriptCommandIsAShellEvent() {
        let events = scriptEvents(#"""
            text(await tools.exec_command({cmd:"git status --short && git log -3 --oneline",workdir:"/Users/x/project/web",max_output_tokens:3000}));

            """#)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].id, "call_Sc1")
        XCTAssertEqual(events[0].source, .codex)
        XCTAssertEqual(events[0].kind, .shell)
        XCTAssertEqual(events[0].toolName, "exec_command")
        XCTAssertEqual(events[0].primary, "git status --short && git log -3 --oneline")
        XCTAssertEqual(events[0].secondary, "in web")
        XCTAssertEqual(events[0].sessionId, "0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000")
        XCTAssertEqual(events[0].cwd, "/Users/x/project")
        XCTAssertEqual(events[0].projectName, "project")
        XCTAssertEqual(events[0].timestamp, ISOTimestamp.date(from: "2026-10-02T09:50:41.299Z"))
        XCTAssertEqual(events[0].transcriptPath, scriptPath)
    }

    func testExecScriptYieldsOneEventPerCall() {
        let events = scriptEvents(#"""
            const results = await Promise.allSettled([
              tools.exec_command({cmd:"pwd && ls","max_output_tokens":2000}),
              tools.exec_command({"cmd":"cat README.md","workdir":"/Users/x/project/docs"}),
              tools.exec_command({
                cmd: "swift test",
                workdir: "/Users/x/elsewhere",
                yield_time_ms: 10000
              }),
            ]);
            text(JSON.stringify(results));
            text(await tools.apply_patch("*** Begin Patch\n*** Add File: notes/todo.md\n+one\n*** End Patch\n"));
            text(await tools.write_stdin({session_id:67417,chars:"y\n",yield_time_ms:1000,max_output_tokens:2000}));
            """#)

        XCTAssertEqual(events.map(\.primary), ["pwd && ls", "cat README.md", "swift test", "notes/todo.md", "y\\n"])
        XCTAssertEqual(events.map(\.secondary), [nil, "in docs", "in /Users/x/elsewhere", "1 add", "sent to terminal 67417"])
        XCTAssertEqual(events.map(\.kind), [.shell, .shell, .shell, .fileEdit, .shell])
        XCTAssertEqual(events.map(\.toolName), ["exec_command", "exec_command", "exec_command", "apply_patch", "write_stdin"])
        XCTAssertEqual(events.map(\.id), ["call_Sc1", "call_Sc1#2", "call_Sc1#3", "call_Sc1#4", "call_Sc1#5"],
                       "each row has its own id, and the first is the record's")
        XCTAssertEqual(Set(events.map(\.sessionId)), ["0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000"], "all under the session, the patch too")
    }

    func testExecScriptStringsAreReadAsJavaScriptWritesThem() {
        let events = scriptEvents(#"""
            text(await tools.exec_command({cmd:"python3 - <<'PY'\nprint(\"caf\u00e9 \\\\ \x41 \u{1F600} \uD83D\uDE00\")\nPY",workdir:'/Users/x/project/it\'s'}));
            text(await tools.exec_command({cmd:`ls -la \
            src
            docs`}));
            text(await tools.apply_patch(String.raw`*** Begin Patch
            *** Update File: C:\new\table.txt
            *** End Patch`));
            """#)

        XCTAssertEqual(events.map(\.primary), [
            "python3 - <<'PY'\nprint(\"caf\u{E9} \\\\ A \u{1F600} \u{1F600}\")\nPY",
            "ls -la src\ndocs",
            #"C:\new\table.txt"#,
        ])
        XCTAssertEqual(events[0].secondary, "in it's")
    }

    func testExecScriptTemplateKeepsItsPlaceholders() {
        let events = scriptEvents(#"""
            const repo = load("repo");
            const r = await tools.exec_command({cmd:`gh run list --repo ${repo.name} --limit ${ n > 5 ? `5` : n }`,workdir:"/Users/x/project"});
            """#)
        XCTAssertEqual(events.map(\.primary), ["gh run list --repo ${repo.name} --limit ${ n > 5 ? `5` : n }"])
    }

    func testExecScriptReadsNamesDeclaredWithALiteral() {
        let events = scriptEvents(#"""
            const patch = "*** Begin Patch\n*** Update File: src/app.swift\n@@\n-a\n+b\n*** End Patch\n";
            const cmd = "swift build", dir = "/Users/x/project/tools"
            text(await tools.apply_patch(patch));
            text(await tools.exec_command({cmd, workdir: dir}));
            """#)
        XCTAssertEqual(events.map(\.primary), ["src/app.swift", "swift build"])
        XCTAssertEqual(events.map(\.secondary), ["1 update", "in tools"])
    }

    func testExecScriptDoesNotGuessWhatItCannotRead() {
        let events = scriptEvents(#"""
            const cmd = "echo outer";
            const jobs = [["a","make a"],["b","make b"]];
            const out = await Promise.all(jobs.map(async ([name, cmd]) => tools.exec_command({cmd, workdir:"/Users/x/project/a"})));
            for (const job of jobs) text(await tools.exec_command({cmd: job[1] + " --verbose"}));
            let line = "make";
            line += " install";
            text(await tools.exec_command({cmd: line}));
            const options = {cmd: "make clean"};
            text(await tools.exec_command(options));
            text(await tools.apply_patch(header + "*** End Patch"));
            text(await tools.write_stdin({session_id, chars: answer}));
            """#)
        XCTAssertEqual(events.map(\.primary), [
            "(computed command)", "(computed command)", "(computed command)", "(computed command)",
            "(computed patch)", "(computed input)",
        ])
        XCTAssertEqual(events.map(\.secondary), ["in a", nil, nil, nil, "patch", "sent to terminal session"])
    }

    func testExecScriptIgnoresCallsThatAreOnlyQuoted() {
        let events = scriptEvents(#"""
            // tools.exec_command({cmd:"not run"})
            /* tools.apply_patch("*** Begin Patch") */
            const hits = lines.filter(l => /"tools\.exec_command\(/.test(l) || l.length / 2 > 10);
            text(await tools.exec_command({cmd:"rg -n 'tools.exec_command({cmd:\"x\"})' src"}));
            text(`see ${note} tools.exec_command({cmd:"also not run"})`);
            """#)
        XCTAssertEqual(events.map(\.primary), [#"rg -n 'tools.exec_command({cmd:"x"})' src"#])
    }

    func testExecScriptThatOnlyLooksYieldsNothing() {
        XCTAssertEqual(scriptEvents(#"""
            text(await tools.view_image({path:"/Users/x/project/shot.png"}));
            text(await tools.web__run({search_query:[{q:"swift regex literal"}]}));
            text(await tools.write_stdin({session_id:67417,chars:"",yield_time_ms:1000,max_output_tokens:2000}));
            text(await tools.write_stdin({session_id:67417,yield_time_ms:5000}));
            const hits = ALL_TOOLS.filter(x => /node.?repl/i.test(x.name)); text(hits);
            """#), [])
    }

    func testJavaScriptToolIsAShellEvent() {
        var context = CodexTranscriptParser.FileContext(sessionId: "s", cwd: "/repo")
        let direct = CodexTranscriptParser.events(fromLine: line([
            "timestamp": "2026-09-14T03:10:00.000Z",
            "ordinal": 41,
            "type": "response_item",
            "payload": [
                "type": "function_call",
                "name": "js",
                "namespace": "mcp__cua_repl",
                "call_id": "call_js",
                "arguments": TranscriptFixtures.json(["code": "await app.pressKey('cmd+s');\n", "title": "Save the document"]),
                "internal_chat_message_metadata_passthrough": ["turn_id": "turn-1"],
            ],
        ]), transcriptPath: "/tmp/s.jsonl", context: &context)

        XCTAssertEqual(direct.map(\.kind), [.shell])
        XCTAssertEqual(direct.first?.toolName, "js")
        XCTAssertEqual(direct.first?.primary, "await app.pressKey('cmd+s');")
        XCTAssertEqual(direct.first?.secondary, "Save the document")
        XCTAssertEqual(direct.first?.sessionId, "s")

        let inScript = scriptEvents(#"text(await tools.mcp__node_repl__js({code:"nodeRepl.write(process.cwd())",title:"Where am I"}));"#)
        XCTAssertEqual(inScript.map(\.toolName), ["js"])
        XCTAssertEqual(inScript.map(\.primary), ["nodeRepl.write(process.cwd())"])
        XCTAssertEqual(inScript.map(\.secondary), ["Where am I"])
    }

    func testToolsThatDoNotTouchTheSystemAreNotEvents() {
        var context = CodexTranscriptParser.FileContext(sessionId: "s", cwd: "/repo")
        let calls: [(name: String, arguments: [String: Any])] = [
            ("wait", ["cell_id": "8", "yield_time_ms": 10000]),
            ("sleep", ["duration_ms": 45000]),
            ("send_message", ["target": "helper", "message": "gAAAAAB"]),
            ("followup_task", ["target": "helper", "message": "gAAAAAB"]),
            ("spawn_agent", ["task_name": "helper", "message": "gAAAAAB"]),
            ("wait_agent", ["timeout_ms": 60000]),
            ("request_user_input_async", ["questions": [["title": "Which one?"]]]),
            ("js_reset", [:]),
            ("view_image", ["path": "/repo/shot.png"]),
            ("update_plan", ["plan": [["step": "Look", "status": "in_progress"]]]),
        ]
        for call in calls {
            let events = CodexTranscriptParser.events(fromLine: line([
                "timestamp": "2026-09-14T03:10:00.000Z",
                "ordinal": 3,
                "type": "response_item",
                "payload": [
                    "type": "function_call", "name": call.name, "call_id": "call_\(call.name)",
                    "arguments": TranscriptFixtures.json(call.arguments),
                ],
            ]), transcriptPath: "/tmp/s.jsonl", context: &context)
            XCTAssertEqual(events, [], call.name)
        }
    }

    func testEventIdLeadsBackToItsRecord() {
        XCTAssertEqual(CodexTranscriptParser.eventId(callId: "call_Sc1", index: 0), "call_Sc1")
        XCTAssertEqual(CodexTranscriptParser.eventId(callId: "call_Sc1", index: 2), "call_Sc1#3")
        for (id, callId) in [("call_Sc1", "call_Sc1"), ("call_Sc1#3", "call_Sc1"), ("call_Sc1#12", "call_Sc1"),
                             ("toolu_01", "toolu_01"), ("a#b", "a#b"), ("a#", "a#"), ("", "")] {
            XCTAssertEqual(CodexTranscriptParser.callId(ofEvent: id), callId, id)
        }
    }
}
