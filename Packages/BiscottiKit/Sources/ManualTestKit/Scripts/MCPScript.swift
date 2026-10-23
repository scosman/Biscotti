/// The MCP Server manual test script.
///
/// One real-client end-to-end pass: the human runs the real Biscotti app,
/// enables the MCP toggle in Settings, connects a real MCP client following
/// the per-agent connection guide, and confirms the three read-only
/// tools list and return sane data. Everything before the client connection
/// is setup instruction; the recordable questions capture the end-to-end
/// verdict and the live port change so `make manual-tests-check` tracks
/// them.
public extension TestScript {
    static let mcp = TestScript(
        id: "mcp_server",
        title: "MCP Server",
        steps: [
            // 1. Setup instruction (passive text)
            .instruction(
                id: "mcp_connect",
                text: "Run the real Biscotti app (not ManualTestApp), open "
                    + "Settings → General, and turn the MCP toggle on. A "
                    + "confirmation alert appears (it appears every time the "
                    + "toggle is turned on) — click “Turn On”. "
                    + "The caption should show the subtitle with a "
                    + "“How to connect” link on the same line. Open the "
                    + "link: the sheet holds the MCP Server URL "
                    + "(http://127.0.0.1:8516/mcp unless the Port field "
                    + "under the toggle says otherwise) with a Copy button and "
                    + "a link to the per-agent connection guide "
                    + "(App/ConnectingMCP.md on GitHub). Use that guide to "
                    + "connect a real MCP client (Claude Desktop, Claude "
                    + "Code, Cursor, …). "
                    + "Then call all three tools: biscotti_query_meetings "
                    + "(e.g. search for a word you know is in a recorded "
                    + "meeting), biscotti_get_meeting, and "
                    + "biscotti_get_transcript on the meeting you found."
            ),
            // 2. Real-client verdict (recordable)
            .humanQuestion(
                id: "mcp_real_client",
                prompt: "In the real MCP client, did all three tools list "
                    + "and return sane data from the real app (search results "
                    + "match, meeting details are correct, transcript text "
                    + "has speaker names and timestamps)? Also confirm the "
                    + "Settings row reflects the running state."
            ),
            // 3. Port change (recordable)
            .humanQuestion(
                id: "mcp_port_change",
                prompt: "With MCP on, change the Port field under the toggle "
                    + "to 8517 and press Return. Does the caption return to "
                    + "running, does “How to connect” show "
                    + "http://127.0.0.1:8517/mcp, and does the client work "
                    + "once its URL is updated to 8517? Does the port survive "
                    + "a relaunch? Does an entry like 80 show “Enter a port "
                    + "from 1024 to 65535.”? Set it back to 8516 afterwards."
            )
        ]
    )
}
