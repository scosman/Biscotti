import Testing
@testable import GraphCalendar

@Suite("HTMLText")
struct HTMLTextTests {
    @Test("line breaks, paragraphs, lists and table cells")
    func structure() {
        #expect(HTMLText.plainText(fromHTML: "<p>One<br>Two<br/>Three</p><p>Four</p>") == "One\nTwo\nThree\n\nFour")
        #expect(
            HTMLText.plainText(fromHTML: "<ul><li>a</li><li>b</li></ul><table><tr><td>x</td><td>y</td></tr></table>")
                == "- a\n- b\n\nx y"
        )
    }

    @Test("head, style, script and comments are dropped")
    func hiddenContent() {
        let html = """
        <html><head><title>Ignore</title><style>p { margin: 0 }</style></head>
        <body><!--[if mso]><p>Outlook only</p><![endif]--><script>alert(1)</script><p>Shown</p></body></html>
        """
        #expect(HTMLText.plainText(fromHTML: html) == "Shown")
    }

    @Test("links keep their target; mailto, anchors and bare URLs do not repeat")
    func anchors() {
        let html = """
        Mail <a href="mailto:pat@synderys.com">Pat</a>, see \
        <a href="https://example.com/a?b=1&amp;c=2">https://example.com/a?b=1&amp;c=2</a> or \
        <a href='https://example.com/x'><b>docs</b></a> and <a href="#top">top</a>.
        """
        #expect(
            HTMLText.plainText(fromHTML: html)
                == "Mail Pat , see https://example.com/a?b=1&c=2 or docs https://example.com/x and top ."
        )
    }

    @Test("entities are decoded exactly once")
    func entities() {
        #expect(HTMLText.plainText(fromHTML: "b &amp;lt; c") == "b &lt; c")
        #expect(HTMLText.plainText(fromHTML: "&#8217;&#x2014;&nbsp;x &AMP; &copy;") == "’— x & ©")
        #expect(HTMLText.plainText(fromHTML: "caf&eacute;") == "caf&eacute;", "unknown entities stay as written")
        #expect(HTMLText.decodeEntities("&#xD800;") == "&#xD800;", "invalid scalars stay as written")
    }

    @Test("whitespace: runs collapse, at most one blank line, no blank edges")
    func whitespace() {
        let text = "\r\n\r\n  Line  one\t\u{00A0}x \r\n\r\n\r\n\r\nLine two  \n\n"
        #expect(HTMLText.plainText(fromText: text) == "Line one x\n\nLine two")
    }

    @Test("long text is cut to the limit and ends in an ellipsis")
    func truncation() {
        let text = String(repeating: "a", count: 50)
        #expect(HTMLText.plainText(fromText: text, limit: 10) == "aaaaaaaaa…")
        #expect(HTMLText.plainText(fromText: text, limit: 50) == text)
        #expect(HTMLText.plainText(fromText: text, limit: nil) == text)
    }
}
