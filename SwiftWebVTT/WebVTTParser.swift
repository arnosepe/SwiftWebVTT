// Adapted from https://www.w3.org/TR/webvtt1/#file-parsing

import Foundation

public enum WebVTTError: Error {
    case invalidSignature
}

public class WebVTTParser {
    fileprivate let scanner: CustomScanner
    fileprivate let references = HTMLCharacterReferences.standard()
    
    fileprivate static let spaceDelimiterSet = CharacterSet(charactersIn: "\u{0020}\u{0009}\u{000A}")
    fileprivate static let newlineSet = CharacterSet(charactersIn: "\u{000A}")
    
    private var seenCue = false
    
    public init(string: String) {
        let string = string
            .replacingOccurrences(of: "\u{0000}", with: "\u{FFFD}")
            .replacingOccurrences(of: "\u{000D}\u{000A}", with: "\u{000A}")
            .replacingOccurrences(of: "\u{000D}", with: "\u{000A}")
        scanner = CustomScanner(string: string)
    }
    
    public func parse() throws -> WebVTT {
        guard
            let signature = scanner.scanUpToCharacters(from: WebVTTParser.spaceDelimiterSet),
            signature == "WEBVTT"
            else { throw WebVTTError.invalidSignature }
        
        scanner.scanUpToCharacters(from: WebVTTParser.newlineSet, thenSkip: 1)
        
        guard !scanner.isAtEnd else { return WebVTT(cues: []) }
        
        if scanner.peekCharacter() != "\u{000A}" {
            _ = parseBlock(inHeader: true)
        } else {
            scanner.skip(1)
        }
        
        scanner.scanCharacters(from: WebVTTParser.newlineSet)
        
        var cues: [WebVTT.Cue] = []
        while !scanner.isAtEnd {
            let block = parseBlock(inHeader: false)
            
            if case .cue(let start, let end, let text)? = block {
                let parsedText = CueTextParser(string: text, references: references)
                    .parse()
                    .compactMap {
                        switch $0 {
                        case .text(let text):
                            return text
                        default:
                            return nil
                        }
                    }
                    .joined()
                let timing = WebVTT.Timing(start: start, end: end)
                cues.append(WebVTT.Cue(timing: timing, text: parsedText))
            }
            
            scanner.scanCharacters(from: WebVTTParser.newlineSet)
        }
        return WebVTT(cues: cues)
    }
    
    fileprivate enum Block {
        case unknown(String)
        case stylesheet(String)
        case region(String)
        case cue(Int, Int, String)
    }
    
    private func parseBlock(inHeader: Bool) -> Block? {
        
        enum BlockType {
            case stylesheet
            case region
            case cue
        }
        
        var lineCount = 0
        var prevPosition = scanner.scanLocation
        var buffer = ""
        var seenEOF = false
        var seenArrow = false
        var cueTiming: (Int, Int)? = nil
        var blockType: BlockType? = nil
        
        while !seenEOF {
            let line = scanner.scanUpToCharacters(from: WebVTTParser.newlineSet, thenSkip: 1)
            lineCount += 1
            seenEOF = scanner.isAtEnd
            if line?.contains("-->") == true {
                if !inHeader, (lineCount == 1 || (lineCount == 2 && !seenArrow)) {
                    seenArrow = true
                    prevPosition = scanner.scanLocation
                    cueTiming = CueInfoParser(string: line!).parse()
                    blockType = .cue
                    buffer = ""
                    seenCue = true
                } else {
                    scanner.scanLocation = prevPosition
                    break
                }
            } else if line == nil || line!.isEmpty {
                break
            } else {
                if !inHeader, lineCount == 2 {
                    if !seenCue, buffer.hasPrefix("STYLE") {
                        // create css
                        blockType = .stylesheet
                        buffer = ""
                    } else if !seenCue, buffer.hasPrefix("REGION") {
                        // create region
                        blockType = .region
                        buffer = ""
                    }
                }
                if !buffer.isEmpty { buffer += "\u{000A}" }
                buffer += line ?? ""
                prevPosition = scanner.scanLocation
            }
        }
        guard blockType != nil else { return .unknown(buffer) }
        switch blockType! {
        case .stylesheet:
            return .stylesheet(buffer)
        case .region:
            return .region(buffer)
        case .cue:
            guard cueTiming != nil else { return nil }
            return .cue(cueTiming!.0, cueTiming!.1, buffer)
        }
    }
}

fileprivate class CueInfoParser {
    let scanner: CustomScanner
    init(string: String) {
        scanner = CustomScanner(string: string)
    }
    
    fileprivate static let separatorSet = CharacterSet(charactersIn: ":.")
    
    func parse() -> (Int, Int)? {
        guard let from = parseTiming() else { return nil }
        scanner.scanCharacters(from: WebVTTParser.spaceDelimiterSet)
        guard scanner.peek(3) == "-->" else { return nil }
        scanner.skip(3)
        scanner.scanCharacters(from: WebVTTParser.spaceDelimiterSet)
        guard let to = parseTiming() else { return nil }
        // followed by optional (whitespace+, settings)
        return (from, to)
    }
    
    func parseTiming() -> Int? {
        guard let value1 = scanner.scanInt(), scanner.peekCharacter() == ":" else { return nil }
        var totalTime: Int = value1 * 60 * 1000
        scanner.skip(1)
        guard let value2 = scanner.scanInt(), let separator = scanner.scanCharacters(from: CueInfoParser.separatorSet) else { return nil }
        if separator == ":" {
            totalTime *= 60
            totalTime += value2 * 60 * 1000
            guard let value3 = scanner.scanInt(), scanner.peekCharacter() == "." else { return nil }
            totalTime += value3 * 1000
            scanner.skip(1)
        } else {
            totalTime += value2 * 1000
        }
        guard let milliseconds = scanner.scanInt() else { return nil }
        totalTime += milliseconds
        
        return totalTime
    }
}

public class CueTextParser {
    public enum Token {
        case text(String)
        case tagStart(String, [String], String?)
        case tagEnd(String)
        case timestamp(String)
    }
    
    let scanner: CustomScanner
    private let references: HTMLCharacterReferences
    public init(string: String, references: HTMLCharacterReferences) {
        scanner = CustomScanner(string: string)
        self.references = references
    }
    public func parse() -> [Token] {
        var tokens: [Token] = []
        while !scanner.isAtEnd {
            let token = parseToken()
            tokens.append(token)
        }
        return tokens
    }
    
    private func parseToken() -> Token {
        enum State {
            case data
            case HTMLCharacterReference
            case tag
            case startTag
            case startTagAnnotation
            case HTMLCharacterReferenceInAnnotation
            case startTagClass
            case endTag
            case timestamp
        }
        var state = State.data
        var result: [Character] = []
        var buffer: [Character] = []
        var classes: [String] = []
        while let c = scanner.scanCharacter() {
            switch state {
            case .data:
                switch c {
                case "&":
                    state = .HTMLCharacterReference
                case "<":
                    if result.isEmpty {
                        state = .tag
                    } else {
                        scanner.skip(-1)
                        return .text(String(result))
                    }
                default:
                    result.append(c)
                }
            case .HTMLCharacterReference:
                scanner.skip(-1)
                result += scanner.handleCharacterReference(references: references)
                state = .data
            case .tag:
                switch c {
                case "\u{0009}", "\u{000A}", "\u{000C}", "\u{0020}":
                    state = .startTagAnnotation
                case "\u{002E}":
                    state = .startTagClass
                case "\u{002F}":
                    state = .endTag
                case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                    result = [c]
                    state = .timestamp
                case ">":
                    scanner.skip(-1)
                    return .tagStart("", classes, nil)
                default:
                    result = [c]
                    state = .startTag
                }
            case .startTag:
                switch c {
                case "\u{0009}", "\u{000C}", "\u{0020}":
                    state = .startTagAnnotation
                case "\u{000A}":
                    buffer = [c]
                    state = .startTagAnnotation
                case ".":
                    state = .startTagClass
                case ">":
                    return .tagStart(String(result), classes, buffer.isEmpty ? nil : String(buffer))
                default:
                    result.append(c)
                }
            case .startTagClass:
                switch c {
                case "\u{0009}", "\u{000C}", "\u{0020}":
                    classes.append(String(buffer))
                    buffer = []
                    state = .startTagAnnotation
                case "\u{000A}":
                    classes.append(String(buffer))
                    buffer = [c]
                    state = .startTagAnnotation
                case ".":
                    classes.append(String(buffer))
                    buffer = []
                    state = .startTagClass
                case ">":
                    classes.append(String(buffer))
                    buffer = []
                    return .tagStart(String(result), classes, nil)
                default:
                    buffer.append(c)
                }
            case .startTagAnnotation:
                switch c {
                case "&":
                    state = .HTMLCharacterReferenceInAnnotation
                case ">":
                    buffer = Array(String(buffer).trimmingCharacters(in: WebVTTParser.spaceDelimiterSet))
                    return .tagStart(String(result), classes, buffer.isEmpty ? nil : String(buffer))
                default:
                    buffer.append(c)
                }
            case .HTMLCharacterReferenceInAnnotation:
                scanner.skip(-1)
                buffer += scanner.handleCharacterReference(references: references, allowedCharacter: ">")
                state = .startTagAnnotation
            case .endTag:
                switch c {
                case ">":
                    return .tagEnd(String(result))
                default:
                    result.append(c)
                }
            case .timestamp:
                switch c {
                case ">":
                    return .timestamp(String(result))
                default:
                    result.append(c)
                }
            }
        }
        return .text(String(result))
    }
}

public class CueTextTree {
    public class Node {
        public let type: NodeType
        
        public let classes: [String]
        public let annotation: String?
        
        public var children: [Node] = []
        
        init(type: NodeType, classes: [String] = [], annotation: String? = nil) {
            self.type = type
            self.classes = classes
            self.annotation = annotation
        }
    }
    
    public enum NodeType: Equatable {
        // Root node
        case root
        
        // Internal nodes
        case `class`
        case italic
        case bold
        case underline
        case ruby
        case rubyText
        case voice
        case language
        
        // Leaves
        case text(String)
        case timestamp(String)
        
        // Only for internal nodes
        init?(_ tag: String) {
            switch tag {
            case "c": self = .class
            case "i": self = .italic
            case "b": self = .bold
            case "u": self = .underline
            case "ruby": self = .ruby
            case "rt": self = .rubyText
            case "v": self = .voice
            case "lang": self = .language
            default: return nil
            }
        }
        
        var isLeaf: Bool {
            switch self {
            case .text(_), .timestamp(_): return true
            default: return false
            }
        }
    }
    
    public let root = Node(type: .root)
    private var stack: [Node] = []
    private var current: Node { return stack.last ?? root }
    
    public init(_ tokens: [CueTextParser.Token]) {
        for token in tokens {
            switch token {
            case .text(let text):
                attach(.text(text))
            case .timestamp(let timestamp):
                attach(.timestamp(timestamp))
            case .tagStart(let tag, let classes, let annotation):
                guard let type = NodeType(tag) else { break }
                let node = Node(type: type, classes: classes, annotation: annotation)
                attach(node)
            case .tagEnd(let tag):
                close(tag)
            }
        }
        stack = []
    }
    
    fileprivate func attach(_ type: NodeType) {
        attach(Node(type: type))
    }
    
    fileprivate func attach(_ node: Node) {
        current.children.append(node)
        guard !node.type.isLeaf else { return }
        stack.append(node)
    }
    
    fileprivate func close(_ tag: String) {
        guard let type = NodeType(tag) else { return }
        if (current.type == type) || (type == .ruby && current.type == .rubyText) {
            stack.removeLast()
        }
    }
}

public extension CueTextTree.Node {
    func attributedString(font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        switch self.type {
        case .text(let text):
            result.append(NSAttributedString(string: text))
        case .timestamp(_):
            break
        case .voice:
            let text = "\(annotation ?? ""): "
            let traits = font.fontDescriptor.symbolicTraits.union([.traitBold])
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { break }
            let attributes = [NSAttributedString.Key.font: UIFont(descriptor: descriptor, size: font.pointSize)]
            result.append(NSAttributedString(string: text, attributes: attributes))
        default: break
        }
        
        children
            .map { $0.attributedString(font: font) }
            .forEach { result.append($0) }
        
        result.addAttributes(attributes(font: font), range: NSRange(location: 0, length: result.length))
        return result
    }
    
    func attributes(font: UIFont) -> [NSAttributedString.Key: Any] {
        switch self.type {
        case .italic:
            let traits = font.fontDescriptor.symbolicTraits.union([.traitItalic])
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { break }
            return [.font: UIFont(descriptor: descriptor, size: font.pointSize)]
        case .bold:
            let traits = font.fontDescriptor.symbolicTraits.union([.traitBold])
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { break }
            return [.font: UIFont(descriptor: descriptor, size: font.pointSize)]
        case .underline:
            return [.underlineStyle: NSUnderlineStyle.single.rawValue]
        case .ruby:
            break
        case .rubyText:
            break
        case .voice:
            break
        case .language:
            break
        case .text(_):
            break
        case .timestamp(_):
            break
        case .root:
            break
        case .class:
            break
        }
        return [:]
    }
}
