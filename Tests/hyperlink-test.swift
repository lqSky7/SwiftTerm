import Foundation

@main
enum HyperlinkTest {
    static func main() {
        let harness = Harness("hyperlink-test")

        testHyperlinkParsing(harness)
        testVTParserOSC8Integration(harness)

        harness.finish()
    }

    private static func testHyperlinkParsing(_ harness: Harness) {
        // Standard OSC 8 with id and URI
        let link = Hyperlink.parse(body: "id=abc;https://warp.dev")
        harness.equal(link?.id, "abc", "Hyperlink id should match")
        harness.equal(link?.uri, "https://warp.dev", "Hyperlink URI should match")

        // OSC 8 without id
        let noIdLink = Hyperlink.parse(body: ";https://github.com")
        harness.equal(noIdLink?.id, nil, "Hyperlink id should be nil")
        harness.equal(noIdLink?.uri, "https://github.com", "Hyperlink URI should match")

        // Multiple parameters (id=xyz:foo=bar)
        let multiParamLink = Hyperlink.parse(body: "foo=bar:id=my-id:baz=qux;https://example.org")
        harness.equal(multiParamLink?.id, "my-id", "Hyperlink id should be extracted from multi-param string")
        harness.equal(multiParamLink?.uri, "https://example.org", "Hyperlink URI should match")

        // URI containing semicolons (matrix params, queries)
        let semicolonUri = Hyperlink.parse(body: "id=1;https://example.com/resource;sessionid=1234?a=1;b=2")
        harness.equal(semicolonUri?.id, "1", "Hyperlink id should match")
        harness.equal(semicolonUri?.uri, "https://example.com/resource;sessionid=1234?a=1;b=2", "URI with semicolons should be preserved")

        // Closing form (empty URI) returns nil
        let closeLink1 = Hyperlink.parse(body: ";")
        harness.equal(closeLink1, nil, "Empty URI closing form should parse to nil")

        let closeLink2 = Hyperlink.parse(body: "id=abc;")
        harness.equal(closeLink2, nil, "Closing form with id should parse to nil")

        // Oversized URI (> 2048 bytes) is rejected
        let hugeUri = "https://example.com/" + String(repeating: "a", count: 2100)
        let rejectedLink = Hyperlink.parse(body: ";\(hugeUri)")
        harness.equal(rejectedLink, nil, "Oversized URI should be rejected")
    }

    private static func testVTParserOSC8Integration(_ harness: Harness) {
        let grid = TerminalGrid(size: TerminalSize(columns: 80, rows: 24))
        let parser = VTParser(grid: grid)

        // Feed OSC 8 open sequence, print text, feed OSC 8 close sequence, print more text
        let openSeq = "\u{1B}]8;id=test;https://warp.dev\u{1B}\\"
        let closeSeq = "\u{1B}]8;;\u{1B}\\"

        parser.feed(openSeq)
        parser.feed("Click Here")
        parser.feed(closeSeq)
        parser.feed(" Normal")

        // First 10 characters ("Click Here") should carry the hyperlink
        for col in 0..<10 {
            let cell = grid.screen[0].cells[col]
            harness.equal(cell.hyperlink?.id, "test", "Cell at column \(col) should have hyperlink id")
            harness.equal(cell.hyperlink?.uri, "https://warp.dev", "Cell at column \(col) should have hyperlink URI")
        }

        // Subsequent characters (" Normal") should not have a hyperlink
        for col in 10..<17 {
            let cell = grid.screen[0].cells[col]
            harness.equal(cell.hyperlink, nil, "Cell at column \(col) should have no hyperlink")
        }
    }
}
