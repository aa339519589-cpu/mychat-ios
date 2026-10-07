import Charts
import SwiftUI

struct VegaLiteArtifactView: View {
    let raw: String
    @State private var chart: VegaChartData?
    @State private var didFail = false

    var body: some View {
        Group {
            if let chart {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let title = chart.title {
                        Text(title)
                            .font(.system(size: 20, weight: .semibold))
                    }
                    Chart(chart.points) { point in
                        switch chart.mark {
                        case .bar:
                            BarMark(
                                x: .value(chart.xTitle, point.x),
                                y: .value(chart.yTitle, point.y)
                            )
                            .foregroundStyle(by: .value("Series", point.series))
                        case .line:
                            LineMark(
                                x: .value(chart.xTitle, point.x),
                                y: .value(chart.yTitle, point.y),
                                series: .value("Series", point.series)
                            )
                            .foregroundStyle(by: .value("Series", point.series))
                            .interpolationMethod(.catmullRom)
                        case .point:
                            PointMark(
                                x: .value(chart.xTitle, point.x),
                                y: .value(chart.yTitle, point.y)
                            )
                            .foregroundStyle(by: .value("Series", point.series))
                        case .area:
                            AreaMark(
                                x: .value(chart.xTitle, point.x),
                                yStart: .value(chart.yTitle, 0),
                                yEnd: .value(chart.yTitle, point.y),
                                series: .value("Series", point.series)
                            )
                            .foregroundStyle(by: .value("Series", point.series))
                        }
                    }
                    .chartLegend(chart.hasSeries ? .visible : .hidden)
                    .frame(minHeight: 340)
                    .accessibilityLabel(chart.title ?? "Data chart")
                }
                .padding(20)
            }
            } else if didFail {
            ArtifactRenderFallback(
                title: "This Vega-Lite specification is not supported yet",
                raw: raw
            )
            } else {
                ProgressView("Rendering chart")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: raw) {
            chart = nil
            didFail = false
            let parsed = await Task.detached(priority: .userInitiated) {
                try? VegaChartData.parse(raw).get()
            }.value
            guard !Task.isCancelled else { return }
            chart = parsed
            didFail = parsed == nil
        }
    }
}

private struct VegaChartData: Sendable {
    enum Mark: String, Sendable {
        case bar
        case line
        case point
        case area
    }

    struct Point: Identifiable, Sendable {
        let id: Int
        let x: String
        let y: Double
        let series: String
    }

    let title: String?
    let mark: Mark
    let xTitle: String
    let yTitle: String
    let hasSeries: Bool
    let points: [Point]

    static func parse(_ raw: String) -> Result<VegaChartData, Error> {
        Result {
            guard raw.utf8.count <= 1_000_000,
                  let root = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)).objectValue,
                  let data = root["data"]?.objectValue,
                  let values = data["values"]?.arrayValue,
                  !values.isEmpty,
                  values.count <= 2_000,
                  let encoding = root["encoding"]?.objectValue,
                  let xEncoding = encoding["x"]?.objectValue,
                  let yEncoding = encoding["y"]?.objectValue,
                  let xField = xEncoding["field"]?.stringValue,
                  let yField = yEncoding["field"]?.stringValue else {
                throw ArtifactRenderError.invalidData
            }

            let markName = root["mark"]?.stringValue
                ?? root["mark"]?.objectValue?["type"]?.stringValue
            guard let markName, let mark = Mark(rawValue: markName.lowercased()) else {
                throw ArtifactRenderError.unsupported
            }
            let colorField = encoding["color"]?.objectValue?["field"]?.stringValue
            var points: [Point] = []
            for (index, value) in values.enumerated() {
                guard let object = value.objectValue,
                      let x = object[xField]?.artifactLabel,
                      let y = object[yField]?.artifactNumber,
                      y.isFinite else { continue }
                let series = colorField.flatMap { object[$0]?.artifactLabel } ?? "Data"
                points.append(Point(id: index, x: x, y: y, series: series))
            }
            guard !points.isEmpty else { throw ArtifactRenderError.invalidData }
            return VegaChartData(
                title: root["title"]?.stringValue,
                mark: mark,
                xTitle: xEncoding["title"]?.stringValue ?? xField,
                yTitle: yEncoding["title"]?.stringValue ?? yField,
                hasSeries: colorField != nil,
                points: points
            )
        }
    }
}

struct FunctionPlotArtifactView: View {
    let raw: String
    @State private var plot: FunctionPlotData?
    @State private var didFail = false

    var body: some View {
        Group {
            if let plot {
            ScrollView {
                Chart {
                    ForEach(plot.segments) { segment in
                        ForEach(segment.points) { point in
                            LineMark(
                                x: .value("x", point.x),
                                y: .value("y", point.y),
                                series: .value("Segment", segment.id)
                            )
                            .foregroundStyle(by: .value("Function", segment.label))
                            .interpolationMethod(.linear)
                        }
                    }
                }
                .chartXScale(domain: plot.xDomain)
                .chartYScale(domain: plot.yDomain)
                .chartLegend(plot.labels.count > 1 ? .visible : .hidden)
                .frame(minHeight: 360)
                .padding(20)
                .accessibilityLabel("Function plot")
            }
            } else if didFail {
            ArtifactRenderFallback(
                title: "This function specification is not supported yet",
                raw: raw
            )
            } else {
                ProgressView("Rendering function")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: raw) {
            plot = nil
            didFail = false
            let parsed = await Task.detached(priority: .userInitiated) {
                try? FunctionPlotData.parse(raw).get()
            }.value
            guard !Task.isCancelled else { return }
            plot = parsed
            didFail = parsed == nil
        }
    }
}

private struct FunctionPlotData: Sendable {
    struct Point: Identifiable, Sendable {
        let id: Int
        let x: Double
        let y: Double
    }

    struct Segment: Identifiable, Sendable {
        let id: String
        let label: String
        let points: [Point]
    }

    let xDomain: ClosedRange<Double>
    let yDomain: ClosedRange<Double>
    let labels: Set<String>
    let segments: [Segment]

    static func parse(_ raw: String) -> Result<FunctionPlotData, Error> {
        Result {
            guard raw.utf8.count <= 100_000,
                  let root = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)).objectValue,
                  let functions = root["data"]?.arrayValue,
                  !functions.isEmpty,
                  functions.count <= 8 else {
                throw ArtifactRenderError.invalidData
            }
            let xDomain = try domain(root["xAxis"], fallback: -10...10)
            let yDomain = try domain(root["yAxis"], fallback: -10...10)
            let sampleCount = 420
            let xSpan = xDomain.upperBound - xDomain.lowerBound
            let ySpan = yDomain.upperBound - yDomain.lowerBound
            var allSegments: [Segment] = []
            var labels = Set<String>()

            for (functionIndex, function) in functions.enumerated() {
                guard let expression = function.objectValue?["fn"]?.stringValue,
                      !expression.isEmpty,
                      expression.utf16.count <= 240 else { continue }
                var current: [Point] = []
                var segmentIndex = 0
                var previousY: Double?

                func finishSegment() {
                    guard current.count >= 2 else {
                        current.removeAll(keepingCapacity: true)
                        return
                    }
                    allSegments.append(Segment(
                        id: "\(functionIndex)-\(segmentIndex)",
                        label: expression,
                        points: current
                    ))
                    segmentIndex += 1
                    current.removeAll(keepingCapacity: true)
                }

                for index in 0...sampleCount {
                    let x = xDomain.lowerBound + xSpan * Double(index) / Double(sampleCount)
                    var parser = MathExpressionParser(expression: expression, x: x)
                    let y = try? parser.evaluate()
                    let discontinuity = y.flatMap { value in
                        previousY.map { abs(value - $0) > ySpan * 1.5 }
                    } ?? false
                    guard let y, y.isFinite, abs(y) < 1e12, !discontinuity else {
                        finishSegment()
                        previousY = nil
                        continue
                    }
                    current.append(Point(id: index, x: x, y: y))
                    previousY = y
                }
                finishSegment()
                labels.insert(expression)
            }
            guard !allSegments.isEmpty else { throw ArtifactRenderError.invalidData }
            return FunctionPlotData(
                xDomain: xDomain,
                yDomain: yDomain,
                labels: labels,
                segments: allSegments
            )
        }
    }

    private static func domain(
        _ value: JSONValue?,
        fallback: ClosedRange<Double>
    ) throws -> ClosedRange<Double> {
        guard let value else { return fallback }
        guard let values = value.objectValue?["domain"]?.arrayValue,
              values.count == 2,
              let lower = values[0].artifactNumber,
              let upper = values[1].artifactNumber,
              lower.isFinite,
              upper.isFinite,
              lower < upper,
              abs(lower) < 1e9,
              abs(upper) < 1e9 else {
            throw ArtifactRenderError.invalidData
        }
        return lower...upper
    }
}

private struct MathExpressionParser {
    private let characters: [Character]
    private let x: Double
    private var index = 0

    init(expression: String, x: Double) {
        characters = Array(expression.lowercased())
        self.x = x
    }

    mutating func evaluate() throws -> Double {
        let value = try expression()
        skipWhitespace()
        guard index == characters.count, value.isFinite else {
            throw ArtifactRenderError.invalidData
        }
        return value
    }

    private mutating func expression() throws -> Double {
        var value = try term()
        while true {
            if consume("+") { value += try term() }
            else if consume("-") { value -= try term() }
            else { return value }
        }
    }

    private mutating func term() throws -> Double {
        var value = try unary()
        while true {
            if consume("*") { value *= try unary() }
            else if consume("/") { value /= try unary() }
            else { return value }
        }
    }

    private mutating func unary() throws -> Double {
        if consume("+") { return try unary() }
        if consume("-") { return -(try unary()) }
        return try power()
    }

    private mutating func power() throws -> Double {
        var value = try primary()
        if consume("^") { value = Foundation.pow(value, try unary()) }
        return value
    }

    private mutating func primary() throws -> Double {
        skipWhitespace()
        if consume("(") {
            let value = try expression()
            guard consume(")") else { throw ArtifactRenderError.invalidData }
            return value
        }
        if let number = number() { return number }
        let name = identifier()
        switch name {
        case "x": return x
        case "pi": return .pi
        case "e": return Foundation.M_E
        default:
            guard !name.isEmpty, consume("(") else { throw ArtifactRenderError.unsupported }
            let argument = try expression()
            guard consume(")") else { throw ArtifactRenderError.invalidData }
            switch name {
            case "sin": return sin(argument)
            case "cos": return cos(argument)
            case "tan": return tan(argument)
            case "asin": return asin(argument)
            case "acos": return acos(argument)
            case "atan": return atan(argument)
            case "sqrt": return sqrt(argument)
            case "abs": return abs(argument)
            case "exp": return exp(argument)
            case "ln", "log": return log(argument)
            case "log10": return log10(argument)
            default: throw ArtifactRenderError.unsupported
            }
        }
    }

    private mutating func number() -> Double? {
        skipWhitespace()
        let start = index
        var sawDigit = false
        while index < characters.count, characters[index].isNumber {
            sawDigit = true
            index += 1
        }
        if index < characters.count, characters[index] == "." {
            index += 1
            while index < characters.count, characters[index].isNumber {
                sawDigit = true
                index += 1
            }
        }
        guard sawDigit else {
            index = start
            return nil
        }
        if index < characters.count, characters[index] == "e" {
            let exponentStart = index
            index += 1
            if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                index += 1
            }
            let digitsStart = index
            while index < characters.count, characters[index].isNumber { index += 1 }
            if digitsStart == index { index = exponentStart }
        }
        return Double(String(characters[start..<index]))
    }

    private mutating func identifier() -> String {
        skipWhitespace()
        let start = index
        while index < characters.count,
              characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
            index += 1
        }
        return String(characters[start..<index])
    }

    private mutating func consume(_ character: Character) -> Bool {
        skipWhitespace()
        guard index < characters.count, characters[index] == character else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < characters.count, characters[index].isWhitespace { index += 1 }
    }
}

struct MermaidArtifactView: View {
    let raw: String
    @State private var diagram: MermaidDiagram?
    @State private var didFail = false

    var body: some View {
        Group {
            if let diagram {
            GeometryReader { proxy in
                let layout = diagram.layout(minimumWidth: proxy.size.width)
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            drawEdges(layout, in: &context)
                            drawNodes(layout, in: &context)
                        }
                        ForEach(layout.nodes) { node in
                            Text(node.label)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(MyChatTheme.text)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .frame(width: node.rect.width - 18, height: node.rect.height - 12)
                                .position(x: node.rect.midX, y: node.rect.midY)
                        }
                    }
                    .frame(width: layout.size.width, height: layout.size.height)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Flow diagram")
                }
            }
            } else if didFail {
            ArtifactRenderFallback(
                title: "This Mermaid diagram is not supported yet",
                raw: raw
            )
            } else {
                ProgressView("Rendering diagram")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: raw) {
            diagram = nil
            didFail = false
            let parsed = await Task.detached(priority: .userInitiated) {
                try? MermaidDiagram.parse(raw).get()
            }.value
            guard !Task.isCancelled else { return }
            diagram = parsed
            didFail = parsed == nil
        }
    }

    private func drawEdges(_ layout: MermaidLayout, in context: inout GraphicsContext) {
        for edge in layout.edges {
            guard let source = layout.nodesByID[edge.source],
                  let target = layout.nodesByID[edge.target] else { continue }
            let start = edgePoint(from: source.rect, toward: target.rect)
            let end = edgePoint(from: target.rect, toward: source.rect)
            var path = Path()
            path.move(to: start)
            let midpoint = layout.direction == .leftToRight
                ? CGPoint(x: (start.x + end.x) / 2, y: start.y)
                : CGPoint(x: start.x, y: (start.y + end.y) / 2)
            let second = layout.direction == .leftToRight
                ? CGPoint(x: (start.x + end.x) / 2, y: end.y)
                : CGPoint(x: end.x, y: (start.y + end.y) / 2)
            path.addLine(to: midpoint)
            path.addLine(to: second)
            path.addLine(to: end)
            context.stroke(path, with: .color(MyChatTheme.secondaryText), lineWidth: 1.5)

            let angle = atan2(end.y - second.y, end.x - second.x)
            var arrow = Path()
            arrow.move(to: end)
            arrow.addLine(to: CGPoint(
                x: end.x - cos(angle - .pi / 6) * 9,
                y: end.y - sin(angle - .pi / 6) * 9
            ))
            arrow.move(to: end)
            arrow.addLine(to: CGPoint(
                x: end.x - cos(angle + .pi / 6) * 9,
                y: end.y - sin(angle + .pi / 6) * 9
            ))
            context.stroke(arrow, with: .color(MyChatTheme.secondaryText), lineWidth: 1.5)
        }
    }

    private func drawNodes(_ layout: MermaidLayout, in context: inout GraphicsContext) {
        for node in layout.nodes {
            let path: Path
            switch node.shape {
            case .rounded:
                path = Path(roundedRect: node.rect, cornerRadius: 14)
            case .circle:
                path = Path(ellipseIn: node.rect)
            case .diamond:
                var diamond = Path()
                diamond.move(to: CGPoint(x: node.rect.midX, y: node.rect.minY))
                diamond.addLine(to: CGPoint(x: node.rect.maxX, y: node.rect.midY))
                diamond.addLine(to: CGPoint(x: node.rect.midX, y: node.rect.maxY))
                diamond.addLine(to: CGPoint(x: node.rect.minX, y: node.rect.midY))
                diamond.closeSubpath()
                path = diamond
            }
            context.fill(path, with: .color(MyChatTheme.raised))
            context.stroke(path, with: .color(MyChatTheme.border), lineWidth: 1)
        }
    }

    private func edgePoint(from source: CGRect, toward target: CGRect) -> CGPoint {
        let dx = target.midX - source.midX
        let dy = target.midY - source.midY
        if abs(dx) * source.height > abs(dy) * source.width {
            return CGPoint(x: dx >= 0 ? source.maxX : source.minX, y: source.midY)
        }
        return CGPoint(x: source.midX, y: dy >= 0 ? source.maxY : source.minY)
    }
}

private struct MermaidDiagram: Sendable {
    enum Direction: Sendable {
        case leftToRight
        case topToBottom
    }

    enum NodeShape: Sendable {
        case rounded
        case circle
        case diamond
    }

    struct Node: Sendable {
        let id: String
        var label: String
        var shape: NodeShape
    }

    struct Edge: Sendable {
        let source: String
        let target: String
    }

    let direction: Direction
    let nodes: [Node]
    let edges: [Edge]

    static func parse(_ raw: String) -> Result<MermaidDiagram, Error> {
        Result {
            guard raw.utf8.count <= 250_000 else { throw ArtifactRenderError.invalidData }
            let lines = raw.components(separatedBy: .newlines)
            guard lines.count <= 600 else { throw ArtifactRenderError.invalidData }
            var direction: Direction = .topToBottom
            var nodes: [Node] = []
            var nodeIndex: [String: Int] = [:]
            var edges: [Edge] = []
            let arrow = try NSRegularExpression(pattern: #"-->|-\.->|==>|---"#)

            func add(_ node: Node) {
                if let index = nodeIndex[node.id] {
                    if nodes[index].label == nodes[index].id, node.label != node.id {
                        nodes[index].label = node.label
                        nodes[index].shape = node.shape
                    }
                    return
                }
                guard nodes.count < 120 else { return }
                nodeIndex[node.id] = nodes.count
                nodes.append(node)
            }

            for originalLine in lines {
                let line = originalLine
                    .replacingOccurrences(of: #"%%.*$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                let lower = line.lowercased()
                if lower.hasPrefix("flowchart ") || lower.hasPrefix("graph ") {
                    if lower.contains(" lr") || lower.hasSuffix("lr") { direction = .leftToRight }
                    continue
                }
                if ["subgraph", "end", "style", "classdef", "class", "click", "linkstyle"]
                    .contains(where: { lower.hasPrefix($0) }) { continue }

                let range = NSRange(line.startIndex..., in: line)
                let matches = arrow.matches(in: line, range: range)
                if matches.isEmpty {
                    if let node = node(from: line) { add(node) }
                    continue
                }

                var parts: [String] = []
                var cursor = line.startIndex
                for match in matches {
                    guard let matchRange = Range(match.range, in: line) else { continue }
                    parts.append(String(line[cursor..<matchRange.lowerBound]))
                    cursor = matchRange.upperBound
                }
                parts.append(String(line[cursor...]))
                guard parts.count >= 2 else { continue }
                for index in 0..<(parts.count - 1) {
                    guard let source = node(from: parts[index]),
                          let target = node(from: parts[index + 1]) else { continue }
                    add(source)
                    add(target)
                    if source.id != target.id, edges.count < 240 {
                        edges.append(Edge(source: source.id, target: target.id))
                    }
                }
            }
            guard !nodes.isEmpty else { throw ArtifactRenderError.invalidData }
            return MermaidDiagram(direction: direction, nodes: nodes, edges: edges)
        }
    }

    func layout(minimumWidth: CGFloat) -> MermaidLayout {
        var indegree = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        var outgoing: [String: [String]] = [:]
        for edge in edges where indegree[edge.source] != nil && indegree[edge.target] != nil {
            indegree[edge.target, default: 0] += 1
            outgoing[edge.source, default: []].append(edge.target)
        }
        var queue = nodes.filter { indegree[$0.id] == 0 }.map(\.id)
        var cursor = 0
        var rank = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        var visited = Set<String>()
        while cursor < queue.count {
            let source = queue[cursor]
            cursor += 1
            visited.insert(source)
            for target in outgoing[source] ?? [] {
                rank[target] = max(rank[target] ?? 0, (rank[source] ?? 0) + 1)
                indegree[target, default: 0] -= 1
                if indegree[target] == 0 { queue.append(target) }
            }
        }
        for (index, node) in nodes.enumerated() where !visited.contains(node.id) {
            rank[node.id] = index % max(1, Int(sqrt(Double(nodes.count))))
        }
        let maxRank = rank.values.max() ?? 0
        let groups = Dictionary(grouping: nodes) { rank[$0.id] ?? 0 }
        let nodeWidth: CGFloat = 150
        let nodeHeight: CGFloat = 66
        let horizontalGap: CGFloat = 60
        let verticalGap: CGFloat = 46
        let padding: CGFloat = 40
        let maxInRank = groups.values.map(\.count).max() ?? 1
        let width: CGFloat
        let height: CGFloat
        switch direction {
        case .leftToRight:
            width = max(minimumWidth, padding * 2 + CGFloat(maxRank + 1) * nodeWidth + CGFloat(maxRank) * horizontalGap)
            height = max(260, padding * 2 + CGFloat(maxInRank) * nodeHeight + CGFloat(maxInRank - 1) * verticalGap)
        case .topToBottom:
            width = max(minimumWidth, padding * 2 + CGFloat(maxInRank) * nodeWidth + CGFloat(maxInRank - 1) * horizontalGap)
            height = max(260, padding * 2 + CGFloat(maxRank + 1) * nodeHeight + CGFloat(maxRank) * verticalGap)
        }

        var layoutNodes: [MermaidLayout.Node] = []
        for currentRank in 0...maxRank {
            let rankedNodes = groups[currentRank] ?? []
            for (position, node) in rankedNodes.enumerated() {
                let center: CGPoint
                switch direction {
                case .leftToRight:
                    let columnX = padding + nodeWidth / 2 + CGFloat(currentRank) * (nodeWidth + horizontalGap)
                    let totalHeight = CGFloat(rankedNodes.count) * nodeHeight
                        + CGFloat(max(0, rankedNodes.count - 1)) * verticalGap
                    center = CGPoint(
                        x: columnX,
                        y: (height - totalHeight) / 2 + nodeHeight / 2
                            + CGFloat(position) * (nodeHeight + verticalGap)
                    )
                case .topToBottom:
                    let rowY = padding + nodeHeight / 2 + CGFloat(currentRank) * (nodeHeight + verticalGap)
                    let totalWidth = CGFloat(rankedNodes.count) * nodeWidth
                        + CGFloat(max(0, rankedNodes.count - 1)) * horizontalGap
                    center = CGPoint(
                        x: (width - totalWidth) / 2 + nodeWidth / 2
                            + CGFloat(position) * (nodeWidth + horizontalGap),
                        y: rowY
                    )
                }
                layoutNodes.append(MermaidLayout.Node(
                    id: node.id,
                    label: node.label,
                    shape: node.shape,
                    rect: CGRect(
                        x: center.x - nodeWidth / 2,
                        y: center.y - nodeHeight / 2,
                        width: nodeWidth,
                        height: nodeHeight
                    )
                ))
            }
        }
        return MermaidLayout(
            direction: direction,
            size: CGSize(width: width, height: height),
            nodes: layoutNodes,
            edges: edges
        )
    }

    private static func node(from value: String) -> Node? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("|"), let end = text.dropFirst().firstIndex(of: "|") {
            text = String(text[text.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let expression = try? NSRegularExpression(
            pattern: #"^([A-Za-z_][A-Za-z0-9_-]*)(.*)$"#
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let idRange = Range(match.range(at: 1), in: text),
              let suffixRange = Range(match.range(at: 2), in: text) else { return nil }
        let id = String(text[idRange])
        let suffix = String(text[suffixRange]).trimmingCharacters(in: .whitespaces)
        let shape: NodeShape
        let rawLabel: String
        if suffix.hasPrefix("(("), suffix.hasSuffix("))") {
            shape = .circle
            rawLabel = String(suffix.dropFirst(2).dropLast(2))
        } else if suffix.hasPrefix("{"), suffix.hasSuffix("}") {
            shape = .diamond
            rawLabel = String(suffix.dropFirst().dropLast())
        } else if (suffix.hasPrefix("[") && suffix.hasSuffix("]"))
                    || (suffix.hasPrefix("(") && suffix.hasSuffix(")")) {
            shape = .rounded
            rawLabel = String(suffix.dropFirst().dropLast())
        } else {
            shape = .rounded
            rawLabel = id
        }
        let label = rawLabel
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return Node(id: id, label: String((label.isEmpty ? id : label).prefix(100)), shape: shape)
    }
}

private struct MermaidLayout {
    struct Node: Identifiable {
        let id: String
        let label: String
        let shape: MermaidDiagram.NodeShape
        let rect: CGRect
    }

    let direction: MermaidDiagram.Direction
    let size: CGSize
    let nodes: [Node]
    let edges: [MermaidDiagram.Edge]

    var nodesByID: [String: Node] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }
}

private struct ArtifactRenderFallback: View {
    let title: String
    let raw: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 14) {
                Label(title, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MyChatTheme.secondaryText)
                Text(raw)
                    .font(.system(size: 14, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum ArtifactRenderError: Error, Sendable {
    case invalidData
    case unsupported
}

private extension JSONValue {
    var artifactNumber: Double? {
        switch self {
        case let .integer(value): return Double(value)
        case let .number(value): return value
        case let .string(value): return Double(value)
        default: return nil
        }
    }

    var artifactLabel: String? {
        switch self {
        case let .string(value): return value
        case let .integer(value): return String(value)
        case let .number(value): return String(format: "%g", value)
        case let .bool(value): return value ? "true" : "false"
        default: return nil
        }
    }
}
