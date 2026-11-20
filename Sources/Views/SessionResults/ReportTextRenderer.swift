import AppKit
import cmark_gfm
import cmark_gfm_extensions

/// Renders a report's Markdown into one attributed string, so the whole report is a single
/// text: ⌘A, dragging and copying cover every paragraph, list and table. Pure and
/// thread-safe; images are never fetched (their alt text stands in).
enum ReportTextRenderer {
    typealias Node = UnsafeMutablePointer<cmark_node>

    struct Palette: @unchecked Sendable {
        var text: NSColor = .labelColor
        var muted: NSColor = .secondaryLabelColor
        var link: NSColor = .linkColor
        var codeBackground: NSColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
        var border: NSColor = .separatorColor
    }

    static let bodySize: CGFloat = 13

    static func render(_ markdown: String, palette: Palette = Palette()) -> NSAttributedString {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return NSAttributedString(string: markdown) }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        markdown.withCString { cmark_parser_feed(parser, $0, strlen($0)) }
        guard let document = cmark_parser_finish(parser) else { return NSAttributedString(string: markdown) }
        defer { cmark_node_free(document) }

        var builder = Builder(palette: palette)
        builder.blocks(of: document, context: .init())
        builder.trimTrailingNewlines()
        return builder.output
    }

    /// Inherited inline and block state while walking the tree.
    private struct Context {
        var bold = false
        var italic = false
        var monospace = false
        var strikethrough = false
        var size = ReportTextRenderer.bodySize
        var link: URL?
        var color: NSColor?
        var indent: CGFloat = 0
        var listDepth = 0
        var textBlocks: [NSTextBlock] = []
        var tight = false
    }

    private struct Builder {
        let palette: Palette
        let output = NSMutableAttributedString()

        init(palette: Palette) { self.palette = palette }

        // MARK: Blocks

        mutating func blocks(of parent: Node, context: Context) {
            var child = cmark_node_first_child(parent)
            while let node = child {
                block(node, context: context)
                child = cmark_node_next(node)
            }
        }

        mutating func block(_ node: Node, context: Context) {
            switch typeName(node) {
            case "paragraph":
                inlines(of: node, context: context)
                endParagraph(context, spacing: context.tight ? 2 : 8)
            case "heading":
                var heading = context
                heading.bold = true
                heading.size = [20, 17, 15, 14, 13, 13][max(0, min(5, Int(cmark_node_get_heading_level(node)) - 1))]
                inlines(of: node, context: heading)
                endParagraph(heading, spacing: 8, before: output.length == 0 ? 0 : 10)
            case "list":
                list(node, context: context)
            case "block_quote":
                var quote = context
                quote.indent += 14
                quote.color = palette.muted
                blocks(of: node, context: quote)
            case "code_block":
                var code = context
                code.monospace = true
                code.size = 12
                var literal = string(cmark_node_get_literal(node))
                while literal.hasSuffix("\n") { literal.removeLast() }
                let block = NSTextBlock()
                block.backgroundColor = palette.codeBackground
                block.setContentWidth(100, type: .percentageValueType)
                block.setWidth(8, type: .absoluteValueType, for: .padding)
                code.textBlocks = context.textBlocks + [block]
                append(literal, context: code)
                endParagraph(code, spacing: 8)
            case "thematic_break":
                var rule = context
                rule.color = palette.border
                append(String(repeating: "─", count: 24), context: rule)
                endParagraph(rule, spacing: 8)
            case "table":
                table(node, context: context)
            case "html_block":
                append(string(cmark_node_get_literal(node)).trimmingCharacters(in: .newlines), context: context)
                endParagraph(context, spacing: 8)
            default:
                blocks(of: node, context: context)
            }
        }

        mutating func list(_ node: Node, context: Context) {
            let ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
            var number = Int(cmark_node_get_list_start(node))
            var item = context
            item.listDepth += 1
            item.indent += 18
            item.tight = cmark_node_get_list_tight(node) != 0
            var child = cmark_node_first_child(node)
            while let entry = child {
                let marker = ordered ? "\(number). " : "• "
                number += 1
                // The marker hangs left of the item's text.
                var markerContext = item
                markerContext.color = palette.muted
                append(marker, context: markerContext)
                let start = output.length
                blocks(of: entry, context: item)
                if output.length == start { endParagraph(item, spacing: item.tight ? 2 : 6) }
                child = cmark_node_next(entry)
            }
            if context.listDepth == 0, output.length > 0 { addSpacingToLastParagraph(8) }
        }

        mutating func table(_ node: Node, context: Context) {
            let columns = Int(cmark_gfm_extensions_get_table_columns(node))
            guard columns > 0 else { return }
            let table = NSTextTable()
            table.numberOfColumns = columns
            table.collapsesBorders = true
            table.setContentWidth(100, type: .percentageValueType)
            var row = 0
            var rowNode = cmark_node_first_child(node)
            while let current = rowNode {
                let isHeader = cmark_gfm_extensions_get_table_row_is_header(current) != 0
                var column = 0
                var cellNode = cmark_node_first_child(current)
                while let cell = cellNode, column < columns {
                    let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                    block.setWidth(0.5, type: .absoluteValueType, for: .border)
                    block.setBorderColor(palette.border)
                    block.setWidth(5, type: .absoluteValueType, for: .padding)
                    if isHeader { block.backgroundColor = palette.codeBackground }
                    var cellContext = context
                    cellContext.bold = isHeader
                    cellContext.textBlocks = context.textBlocks + [block]
                    let start = output.length
                    inlines(of: cell, context: cellContext)
                    if output.length == start { append(" ", context: cellContext) }
                    endParagraph(cellContext, spacing: 0)
                    column += 1
                    cellNode = cmark_node_next(cell)
                }
                row += 1
                rowNode = cmark_node_next(current)
            }
            addSpacingToLastParagraph(10)
        }

        // MARK: Inlines

        mutating func inlines(of parent: Node, context: Context) {
            var child = cmark_node_first_child(parent)
            while let node = child {
                inline(node, context: context)
                child = cmark_node_next(node)
            }
        }

        mutating func inline(_ node: Node, context: Context) {
            var inner = context
            switch typeName(node) {
            case "text", "html_inline":
                append(string(cmark_node_get_literal(node)), context: context)
            case "softbreak":
                append(" ", context: context)
            case "linebreak":
                append("\u{2028}", context: context)
            case "code":
                inner.monospace = true
                inner.size = context.size - 1
                append(string(cmark_node_get_literal(node)), context: inner, background: palette.codeBackground)
            case "emph":
                inner.italic = true
                inlines(of: node, context: inner)
            case "strong":
                inner.bold = true
                inlines(of: node, context: inner)
            case "strikethrough":
                inner.strikethrough = true
                inlines(of: node, context: inner)
            case "link":
                inner.link = URL(string: string(cmark_node_get_url(node)))
                inlines(of: node, context: inner)
            case "image":
                inner.color = palette.muted
                append("🖼 ", context: inner)
                inlines(of: node, context: inner)
            default:
                inlines(of: node, context: context)
            }
        }

        // MARK: Output

        func font(_ context: Context) -> NSFont {
            var font = context.monospace
                ? NSFont.monospacedSystemFont(ofSize: context.size, weight: context.bold ? .semibold : .regular)
                : NSFont.systemFont(ofSize: context.size, weight: context.bold ? .semibold : .regular)
            if context.italic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            return font
        }

        func paragraphStyle(_ context: Context, spacing: CGFloat, before: CGFloat = 0) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = spacing
            style.paragraphSpacingBefore = before
            style.lineSpacing = 2
            style.textBlocks = context.textBlocks
            if context.listDepth > 0 {
                style.firstLineHeadIndent = context.indent - 18
                style.headIndent = context.indent
                style.tabStops = []
            } else {
                style.firstLineHeadIndent = context.indent
                style.headIndent = context.indent
            }
            return style
        }

        mutating func append(_ text: String, context: Context, background: NSColor? = nil) {
            guard !text.isEmpty else { return }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(context),
                .foregroundColor: context.link != nil ? palette.link : (context.color ?? palette.text),
                .paragraphStyle: paragraphStyle(context, spacing: 0),
            ]
            if let link = context.link { attributes[.link] = link }
            if context.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let background { attributes[.backgroundColor] = background }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }

        /// Ends the current paragraph and applies its style to the whole paragraph.
        mutating func endParagraph(_ context: Context, spacing: CGFloat, before: CGFloat = 0) {
            let text = output.string as NSString
            let end = output.length
            let start = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: end)).upperBoundOrZero
            output.append(NSAttributedString(string: "\n", attributes: [.font: font(context)]))
            output.addAttribute(.paragraphStyle, value: paragraphStyle(context, spacing: spacing, before: before),
                                range: NSRange(location: start, length: output.length - start))
        }

        mutating func addSpacingToLastParagraph(_ spacing: CGFloat) {
            guard output.length > 0,
                  let style = output.attribute(.paragraphStyle, at: output.length - 1, effectiveRange: nil) as? NSParagraphStyle,
                  let updated = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            updated.paragraphSpacing = max(updated.paragraphSpacing, spacing)
            let text = output.string as NSString
            let start = text.range(of: "\n", options: .backwards,
                                   range: NSRange(location: 0, length: output.length - 1)).upperBoundOrZero
            output.addAttribute(.paragraphStyle, value: updated, range: NSRange(location: start, length: output.length - start))
        }

        mutating func trimTrailingNewlines() {
            while output.length > 0, output.string.hasSuffix("\n") {
                output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
            }
        }

        func typeName(_ node: Node) -> String { string(cmark_node_get_type_string(node)) }
        func string(_ pointer: UnsafePointer<CChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }
    }
}

private extension NSRange {
    /// For a backwards search: the index just after the match, or 0 when nothing matched.
    var upperBoundOrZero: Int { location == NSNotFound ? 0 : location + length }
}
