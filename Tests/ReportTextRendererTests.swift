import AppKit
import XCTest
@testable import PeachyPet

final class ReportTextRendererTests: XCTestCase {
    private let markdown = """
    # 结论

    第一段，有 **加粗**、`code` 和[链接](https://example.com)。

    - 第一项
      - 子项
    - 第二项

    1. 步骤一
    2. 步骤二

    | 运行 | 结果 |
    |---|---|
    | A1 | 通过 |

    ```swift
    let x = 1
    ```

    ![截图](https://example.com/shot.png)
    """

    /// The whole report is one text, so ⌘A and dragging cover every block.
    func testWholeReportIsOneSelectableText() {
        let text = ReportTextRenderer.render(markdown).string
        for piece in ["结论", "第一段", "加粗", "code", "链接", "• 第一项", "子项", "• 第二项", "1. 步骤一", "2. 步骤二",
                      "运行", "通过", "let x = 1"] {
            XCTAssertTrue(text.contains(piece), piece)
        }
        XCTAssertLessThan(text.range(of: "结论")!.lowerBound, text.range(of: "let x = 1")!.lowerBound)
    }

    func testInlineStylesLinksAndImagePlaceholder() throws {
        let rendered = ReportTextRenderer.render(markdown)
        let ns = rendered.string as NSString
        let link = rendered.attribute(.link, at: ns.range(of: "链接").location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://example.com")
        let code = try XCTUnwrap(rendered.attribute(.font, at: ns.range(of: "let x").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(code.fontDescriptor.symbolicTraits.contains(.monoSpace))
        let bold = try XCTUnwrap(rendered.attribute(.font, at: ns.range(of: "加粗").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
        // Images are never fetched; the alt text stands in.
        XCTAssertTrue(rendered.string.contains("截图"))
        XCTAssertNil(rendered.attribute(.attachment, at: ns.range(of: "截图").location, effectiveRange: nil))
    }

    func testRendersOffTheMainThread() {
        let done = expectation(description: "rendered")
        DispatchQueue.global().async {
            XCTAssertFalse(ReportTextRenderer.render(self.markdown).string.isEmpty)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testReportViewIsSelectableAndReadOnly() {
        let scroll = ReportTextView.makeScrollView()
        let textView = scroll.documentView as? NSTextView
        XCTAssertEqual(textView?.isSelectable, true)
        XCTAssertEqual(textView?.isEditable, false)
    }
}
