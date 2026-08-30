/// The MCP Server manual test script.
///
/// One real-client end-to-end pass: the human runs the real Biscotti app,
/// enables the MCP toggle in Settings, connects a real MCP client using the
/// snippet from the How-to-connect sheet, and confirms the three read-only
/// tools list and return sane data. Everything before the client connection
/// is setup instruction; the single recordable question captures the
/// end-to-end verdict so `make manual-tests-check` tracks it.
public extension TestScript {
    static let mcp = TestScript(
        id: "mcp_server",
        title: "MCP Server",
        steps: [
            // 1. Setup instruction (passive text)
            .instruction(
                id: "mcp_connect",
                text: "Run the real Biscotti app (not ManualTestApp), open "
                    + "Settings → General, and turn the MCP toggle on. "
                    + "The caption should show the endpoint "
                    + "http://127.0.0.1:8516/mcp. Open “How to connect” "
                    + "and paste the JSON snippet into a real MCP client "
                    + "(Claude Desktop, Claude Code, Cursor, …). "
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
            )
        ]
    )
}
