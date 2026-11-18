import Foundation
import Testing
@testable import KontorInterchange

@Suite struct XMLTreeTests {
    private func tree(_ xml: String) throws -> XMLTree { try XMLTree(parsing: Array(xml.utf8)) }

    @Test func parsesElementsAttributesAndText() throws {
        let t = try tree("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- comment -->
        <root a="1" b='two &amp; three'>
          <child>Tom &amp; Jerry &lt;3 &#8364; &#x20AC; &apos;q&apos;</child>
          <empty/>
          <child><![CDATA[<raw & unescaped>]]> tail</child>
        </root>
        """)
        #expect(t.name(of: t.root) == "root")
        #expect(t.attribute(t.root, t.nameID("a")) == "1")
        #expect(t.attribute(t.root, t.nameID("b")) == "two & three")
        #expect(t.attribute(t.root, t.nameID("missing")) == nil)
        let children = Array(t.children(of: t.root))
        #expect(children.map { t.name(of: $0) } == ["child", "empty", "child"])
        #expect(t.text(of: children[0]) == "Tom & Jerry <3 € € 'q'")
        #expect(t.text(of: children[1]) == "")
        #expect(t.text(of: children[2]) == "<raw & unescaped> tail")
        #expect(t.child(t.root, t.nameID("child"), index: 2) == children[2])
        #expect(t.child(t.root, t.nameID("child"), index: 3) == nil)
        #expect(t.parent(of: children[1]) == t.root)
        #expect(t.line(of: children[1]) == 5)
    }

    @Test func handlesByteOrderMarksAndUTF16() throws {
        let xml = "<a><b>Größe</b></a>"
        let withBOM = try XMLTree(parsing: [0xEF, 0xBB, 0xBF] + Array(xml.utf8))
        #expect(withBOM.text(of: withBOM.child(withBOM.root, withBOM.nameID("b"))!) == "Größe")
        var utf16: [UInt8] = [0xFF, 0xFE]
        for unit in xml.utf16 { utf16.append(UInt8(unit & 0xFF)); utf16.append(UInt8(unit >> 8)) }
        let wide = try XMLTree(parsing: utf16)
        #expect(wide.text(of: wide.child(wide.root, wide.nameID("b"))!) == "Größe")
    }

    @Test func skipsDoctype() throws {
        let t = try tree("<!DOCTYPE client [ <!ENTITY x \"y\"> ]><client><version>1</version></client>")
        #expect(t.name(of: t.root) == "client")
    }

    @Test(arguments: [
        ("<a><b></a>", 1), ("<a>\n<b>\n</b>", 3), ("<a attr=1/>", 1), ("<a></a><b/>", 1), ("", 1), ("<a>\n\n<b x='1></b></a>", 3), ("just text", 1),
    ])
    func reportsMalformedInput(xml: String, line: Int) {
        do {
            _ = try XMLTree(parsing: Array(xml.utf8))
            Issue.record("expected a syntax error for \(xml)")
        } catch let error as XMLSyntaxError {
            #expect(error.line == line, "\(error.message)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func survivesDeepNesting() throws {
        let depth = 20_000
        let xml = String(repeating: "<n>", count: depth) + "x" + String(repeating: "</n>", count: depth)
        let t = try tree(xml)
        #expect(t.nodes.count == depth)
    }
}

@Suite struct XStreamReferenceTests {
    private func graph(_ xml: String) throws -> XStreamGraph { XStreamGraph(try XMLTree(parsing: Array(xml.utf8))) }

    @Test func resolvesRelativePathsWithIndexes() throws {
        let g = try graph("""
        <client>
          <securities>
            <security><name>A</name></security>
            <security><name>B</name></security>
            <security><name>C</name></security>
          </securities>
          <watchlists>
            <watchlist>
              <securities>
                <security reference="../../../../securities/security[3]"/>
                <security reference="../../../../securities/security"/>
                <security reference="../security"/>
                <security reference="/client/securities/security[2]"/>
                <security reference="../../../../securities/security[4]"/>
              </securities>
            </watchlist>
          </watchlists>
        </client>
        """)
        let t = g.tree
        let list = t.child(t.child(t.child(t.root, t.nameID("watchlists"))!, t.nameID("watchlist"))!, t.nameID("securities"))!
        let names = t.children(of: list).map { node -> String? in
            g.resolve(node).map { t.text(of: t.child($0, t.nameID("name"))!) }
        }
        // third entry: a reference to a reference (chain) resolves to the final object
        #expect(names == ["C", "A", "C", "B", nil])
        #expect(g.unresolved.count == 1)
        #expect(g.isReference(Array(t.children(of: list))[0]))
        #expect(!g.isReference(t.root))
    }

    @Test func resolvesIDReferences() throws {
        let g = try graph("""
        <client id="1">
          <a id="2"><id>not-an-object-id</id><name>first</name></a>
          <b reference="2"/>
          <c reference="99"/>
        </client>
        """)
        let t = g.tree
        let b = t.child(t.root, t.nameID("b"))!
        #expect(g.resolve(b) == t.child(t.root, t.nameID("a")))
        #expect(g.resolve(t.child(t.root, t.nameID("c"))!) == nil)
        #expect(g.unresolved.count == 1)
    }

    @Test func detectsReferenceCycles() throws {
        let g = try graph("<r><a reference=\"../b\"/><b reference=\"../a\"/></r>")
        #expect(g.resolve(g.tree.child(g.tree.root, g.tree.nameID("a"))!) == nil)
    }

    @Test func writerProducesXStreamStylePaths() throws {
        final class Thing: XStreamObject {}
        for style in [XStreamWriter.ReferenceStyle.xpath, .id] {
            var w = XStreamWriter(style: style)
            let root = Thing(), first = Thing(), second = Thing()
            w.object(root, as: "client") { w in
                w.open("items")
                w.object(first, as: "item") { w in
                    w.leaf("name", "one & <two>")
                    w.object(root, as: "owner") { _ in }
                }
                w.object(second, as: "item") { w in
                    w.leaf("name", "second")
                    w.object(first, as: "sibling") { _ in }
                }
                w.close("items")
                w.open("refs")
                w.object(second, as: "item") { _ in }
                w.empty("flag", attributes: [("on", "a\"b")])
                w.close("refs")
            }
            let xml = String(decoding: w.output, as: UTF8.self)
            if style == .xpath {
                #expect(xml.contains("<owner reference=\"../../..\"/>"))
                #expect(xml.contains("<sibling reference=\"../../item\"/>"))
                #expect(xml.contains("<item reference=\"../../items/item[2]\"/>"))
            } else {
                #expect(xml.hasPrefix("<client id=\"1\">"))
                #expect(xml.contains("<owner reference=\"1\"/>"))
                #expect(xml.contains("<sibling reference=\"2\"/>"))
                #expect(xml.contains("<item reference=\"3\"/>"))
            }
            #expect(xml.contains("<name>one &amp; &lt;two&gt;</name>"))
            #expect(xml.contains("<flag on=\"a&quot;b\"/>"))
            // What was written resolves back to the same structure.
            let g = try graph(xml)
            let t = g.tree
            let items = Array(t.children(of: t.child(t.root, t.nameID("items"))!))
            #expect(g.resolve(t.child(items[0], t.nameID("owner"))!) == t.root)
            #expect(g.resolve(t.child(items[1], t.nameID("sibling"))!) == items[0])
            #expect(g.resolve(t.child(t.child(t.root, t.nameID("refs"))!, t.nameID("item"))!) == items[1])
            #expect(g.unresolved.isEmpty)
        }
    }
}

@Suite struct InflateTests {
    @Test func inflatesFixedStoredAndDynamicBlocks() throws {
        let text = Array("hello hello hello, portfolio!".utf8)
        let fixed = Data(base64Encoded: "y0jNyclXyECQOgoF+UUlafk5mfmKAA==")!
        let stored = Data(base64Encoded: "AR0A4v9oZWxsbyBoZWxsbyBoZWxsbywgcG9ydGZvbGlvIQ==")!
        #expect(try Inflate.inflate(fixed) == text)
        #expect(try Inflate.inflate(stored) == text)
        let dynamic = Data(base64Encoded: "C8lIVSgszUzOVkgqyi/PU0jLr1DIKs0tKFbIL0stUigBSuckVlUqpOSn6ymEjCoeVTyqeFTxqOJRxcNLMQMjEzMLKxs7BycXNw8vH7+AoJCwiKiYuISklLSMrJy8gqKSsoqqmrqGppa2jq6evoGhkbGJqZm5haWVtY2tnb2Do5Ozi6ubu4enl7ePr59/QGBQcEhoWHhEZFR0TGxcfEJiUnJKalp6RmZWdk5uXn5BYVFxSWlZeUVlVXVNbV19Q2NTc0trW3tHZ1d3T29f/4SJkyZPmTpt+oyZs2bPmTtv/oKFixYvWbps+YqVq1avWbtu/YaNmzZv2bpt+46du3bv2btv/4GDhw4fOXrs+ImTp06fOXvu/IWLly5fuXrt+o2bt27fuXvv/oOHjx4/efrs+YuXr16/efvu/YePnz5/+frt+4+fv37/+fvv/6j/R7b/AQ==")!
        let output = try Inflate.inflate(dynamic)
        #expect(output.count == 2568)
        #expect(CRC32.checksum(output) == 2_986_644_398)
        #expect(String(decoding: output.prefix(19), as: UTF8.self) == "The quick brown fox")
    }

    @Test func rejectsCorruptAndOversizedStreams() {
        #expect(throws: Inflate.Failure.self) { try Inflate.inflate([0xFF, 0xFF, 0xFF]) }
        #expect(throws: Inflate.Failure.self) { try Inflate.inflate(Data(base64Encoded: "y0jNyclXyECQOgoF")!) } // truncated
        let fixed = Data(base64Encoded: "y0jNyclXyECQOgoF+UUlafk5mfmKAA==")!
        #expect(throws: Inflate.Failure.self) { try Inflate.inflate(fixed, limit: 10) }
    }

    @Test func readsZipArchives() throws {
        let zipped = try Fixture.data("pp/client69.xml.zip")
        let archive = try ZipArchive([UInt8](zipped))
        #expect(archive.entries.map(\.name) == ["data.xml"])
        #expect(archive.entries[0].method == 8)
        let contents = try archive.contents(of: archive.entries[0])
        #expect(Data(contents) == (try Fixture.data("pp/client69.xml")))

        // PP's own container uses a streaming ZIP (sizes in a trailing data descriptor).
        let binary = try ZipArchive([UInt8](try Fixture.data("pp/client69.binary.portfolio")))
        #expect(binary.entries.map(\.name) == ["data.portfolio"])
        let payload = try binary.contents(of: binary.entries[0])
        #expect(payload.count == 3983)
        #expect(payload.starts(with: Array("PPPBV1".utf8)))
    }
}
