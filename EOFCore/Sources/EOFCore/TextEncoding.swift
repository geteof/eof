import Foundation

public struct TextEncoding: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var encoding: String.Encoding
    /// Bytes written before the text when saving.
    public var bom: [UInt8]

    public init(id: String, name: String, encoding: String.Encoding, bom: [UInt8] = []) {
        self.id = id
        self.name = name
        self.encoding = encoding
        self.bom = bom
    }

    // NSStringEncoding values for encodings Foundation has no named constant for.
    private static func ns(_ raw: UInt) -> String.Encoding { String.Encoding(rawValue: raw) }

    public static let utf8 = TextEncoding(id: "utf-8", name: "UTF-8", encoding: .utf8)
    public static let utf8BOM = TextEncoding(id: "utf-8-bom", name: "UTF-8 with BOM", encoding: .utf8, bom: [0xEF, 0xBB, 0xBF])
    public static let utf16LE = TextEncoding(id: "utf-16le", name: "UTF-16 LE", encoding: .utf16LittleEndian, bom: [0xFF, 0xFE])
    public static let utf16BE = TextEncoding(id: "utf-16be", name: "UTF-16 BE", encoding: .utf16BigEndian, bom: [0xFE, 0xFF])
    public static let utf16LENoBOM = TextEncoding(id: "utf-16le-nobom", name: "UTF-16 LE (no BOM)", encoding: .utf16LittleEndian)
    public static let utf16BENoBOM = TextEncoding(id: "utf-16be-nobom", name: "UTF-16 BE (no BOM)", encoding: .utf16BigEndian)
    public static let utf32LE = TextEncoding(id: "utf-32le", name: "UTF-32 LE", encoding: .utf32LittleEndian, bom: [0xFF, 0xFE, 0x00, 0x00])
    public static let utf32BE = TextEncoding(id: "utf-32be", name: "UTF-32 BE", encoding: .utf32BigEndian, bom: [0x00, 0x00, 0xFE, 0xFF])
    public static let gb18030 = TextEncoding(id: "gb18030", name: "Chinese (GB 18030)", encoding: ns(0x8000_0632))
    public static let big5 = TextEncoding(id: "big5", name: "Chinese (Big5)", encoding: ns(0x8000_0A03))
    public static let shiftJIS = TextEncoding(id: "shift-jis", name: "Japanese (Shift JIS)", encoding: .shiftJIS)
    public static let eucJP = TextEncoding(id: "euc-jp", name: "Japanese (EUC)", encoding: .japaneseEUC)
    public static let eucKR = TextEncoding(id: "euc-kr", name: "Korean (EUC)", encoding: ns(0x8000_0940))
    public static let windows1252 = TextEncoding(id: "windows-1252", name: "Western (Windows-1252)", encoding: .windowsCP1252)
    public static let latin1 = TextEncoding(id: "iso-8859-1", name: "Western (ISO Latin 1)", encoding: .isoLatin1)
    public static let windows1251 = TextEncoding(id: "windows-1251", name: "Cyrillic (Windows-1251)", encoding: .windowsCP1251)
    public static let koi8r = TextEncoding(id: "koi8-r", name: "Cyrillic (KOI8-R)", encoding: ns(0x8000_0A02))
    public static let macRoman = TextEncoding(id: "macintosh", name: "Western (Mac OS Roman)", encoding: .macOSRoman)
    public static let ascii = TextEncoding(id: "us-ascii", name: "ASCII", encoding: .ascii)

    public static let all: [TextEncoding] = [
        utf8, utf8BOM, utf16LE, utf16BE, utf16LENoBOM, utf16BENoBOM, utf32LE, utf32BE,
        gb18030, big5, shiftJIS, eucJP, eucKR,
        windows1252, latin1, macRoman, windows1251, koi8r, ascii,
    ]

    public static func named(_ id: String) -> TextEncoding? { all.first { $0.id == id } }

    // MARK: - Decoding

    /// Decodes `data` with this encoding. A leading BOM that belongs to the encoding is dropped.
    public func decode(_ data: Data) -> String? {
        var body = data
        if !bom.isEmpty, data.starts(with: bom) {
            body = data.dropFirst(bom.count)
        } else if encoding == .utf8, data.starts(with: TextEncoding.utf8BOM.bom) {
            body = data.dropFirst(3)
        }
        if encoding == .utf8 {
            // String(data:encoding:) repairs nothing; be strict so detection can fall through.
            return String(data: Data(body), encoding: .utf8)
        }
        return String(data: Data(body), encoding: encoding)
    }

    /// Encodes `text`, or returns nil when it holds characters this encoding cannot represent.
    public func encode(_ text: String) -> Data? {
        guard let body = text.data(using: encoding, allowLossyConversion: false) else { return nil }
        // Foundation adds its own BOM for the plain `.utf16`/`.utf32` encodings only; ours are explicit-endian.
        return Data(bom) + body
    }

    public struct Detection: Sendable {
        public var text: String
        public var encoding: TextEncoding

        public init(text: String, encoding: TextEncoding) {
            self.text = text
            self.encoding = encoding
        }
    }

    /// True when the bytes look like something other than text.
    public static func looksBinary(_ data: Data) -> Bool {
        if data.isEmpty { return false }
        if detectBOM(data) != nil { return false }
        let sample = data.prefix(8192)
        var zeros = 0, control = 0
        for byte in sample {
            if byte == 0 { zeros += 1 }
            else if byte < 9 || (byte > 13 && byte < 27) || (byte > 27 && byte < 32) { control += 1 }
        }
        if zeros == 0 { return control * 20 > sample.count }
        // BOM-less UTF-16 has a NUL in every other byte for ASCII-heavy text.
        return utf16Guess(sample) == nil
    }

    private static func detectBOM(_ data: Data) -> TextEncoding? {
        if data.starts(with: utf32LE.bom) { return utf32LE }
        if data.starts(with: utf32BE.bom) { return utf32BE }
        if data.starts(with: utf8BOM.bom) { return utf8BOM }
        if data.starts(with: utf16LE.bom) { return utf16LE }
        if data.starts(with: utf16BE.bom) { return utf16BE }
        return nil
    }

    private static func utf16Guess(_ sample: Data) -> TextEncoding? {
        guard sample.count >= 4, sample.count % 2 == 0 || sample.count > 64 else { return nil }
        var evenZeros = 0, oddZeros = 0
        var index = 0
        for byte in sample {
            if byte == 0 { if index % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 } }
            index += 1
        }
        let half = sample.count / 2
        if oddZeros * 10 > half * 6, evenZeros * 10 < half { return utf16LENoBOM }
        if evenZeros * 10 > half * 6, oddZeros * 10 < half { return utf16BENoBOM }
        return nil
    }

    /// Finds the encoding of `data`. `preferred` breaks ties among legacy multi-byte encodings.
    public static func detect(_ data: Data, preferred: [TextEncoding] = []) -> Detection? {
        if data.isEmpty { return Detection(text: "", encoding: utf8) }
        if let bom = detectBOM(data), let text = bom.decode(data) {
            return Detection(text: text, encoding: bom)
        }
        // ASCII-heavy UTF-16 without a BOM is also valid UTF-8 (full of NULs), so check it first.
        if data.prefix(8192).contains(0), let guess = utf16Guess(data.prefix(8192)), let text = guess.decode(data) {
            return Detection(text: text, encoding: guess)
        }
        if let text = utf8.decode(data) {
            return Detection(text: text, encoding: utf8)
        }
        if looksBinary(data) { return nil }
        if let guess = legacyGuess(data.prefix(65_536), preferred: preferred, canDecode: { $0.decode(data) != nil }),
           let text = guess.decode(data) {
            return Detection(text: text, encoding: guess)
        }
        if let text = windows1252.decode(data) { return Detection(text: text, encoding: windows1252) }
        // ISO Latin 1 maps every byte, so this never fails.
        return latin1.decode(data).map { Detection(text: $0, encoding: latin1) }
    }

    /// How much of the multi-byte content falls in the part of an encoding that everyday text uses
    /// (kana, hangul, the frequent-character planes), from 0 to 1. Looking at the bytes separates the
    /// East Asian encodings far better than judging the decoded text, because a wrong decoding
    /// still yields real-looking characters.
    static func legacyScore(_ bytes: [UInt8], as encoding: TextEncoding) -> (score: Double, spaces: Int, characters: Int) {
        var weight = 0.0
        var characters = 0
        var spaces = 0
        var lowTrails = 0
        var i = 0
        let n = bytes.count
        func highTrail(_ t: UInt8) -> Bool { t >= 0xA1 && t <= 0xFE }
        while i < n {
            let b = bytes[i]
            if b < 0x80 {
                if b == 0x20 { spaces += 1 }
                i += 1
                continue
            }
            let t: UInt8 = i + 1 < n ? bytes[i + 1] : 0
            characters += 1
            switch encoding.id {
            case "gb18030":
                if t >= 0x30, t <= 0x39 { i += 4; continue } // four-byte form: rare characters
                if highTrail(t), (b >= 0xB0 && b <= 0xD7) || b == 0xA1 || b == 0xA3 { weight += 1 }
                i += t >= 0x40 ? 2 : 1
            case "big5":
                let trail = (t >= 0x40 && t <= 0x7E) || highTrail(t)
                if trail, b >= 0xA1, b <= 0xC6 { weight += 1 }
                if trail, t <= 0x7E { lowTrails += 1 }
                i += trail ? 2 : 1
            case "shift-jis":
                if b >= 0xA1, b <= 0xDF { i += 1; continue } // half-width katakana: almost never real text
                let trail = (t >= 0x40 && t <= 0x7E) || (t >= 0x80 && t <= 0xFC)
                if trail {
                    if (b == 0x82 && t >= 0x9F && t <= 0xF1) || (b == 0x83 && t >= 0x40 && t <= 0x96) || (b == 0x81 && t <= 0xAC) { weight += 1 }
                    else if b >= 0x88, b <= 0x9F { weight += 0.6 }
                    else if b >= 0xE0, b <= 0xEA { weight += 0.3 }
                }
                i += trail ? 2 : 1
            case "euc-kr":
                if highTrail(t), (b >= 0xB0 && b <= 0xC8) || b == 0xA1 || b == 0xA3 { weight += 1 }
                i += highTrail(t) ? 2 : 1
            case "euc-jp":
                if highTrail(t) {
                    if b == 0xA4 || b == 0xA5 || b == 0xA1 { weight += 1 }
                    else if b >= 0xB0, b <= 0xCF { weight += 0.6 }
                }
                i += highTrail(t) ? 2 : 1
            default:
                i += 1
            }
        }
        // About four in ten Big5 characters end in an ASCII-range byte. Text with none of them is EUC.
        if encoding.id == "big5", characters >= 10, lowTrails == 0 { weight *= 0.5 }
        return (characters == 0 ? 0 : weight / Double(characters), spaces, characters)
    }

    /// The East Asian encoding that best explains the bytes, or nil when none does (Western text).
    static func legacyGuess(_ data: Data, preferred: [TextEncoding] = [], canDecode: (TextEncoding) -> Bool = { _ in true }) -> TextEncoding? {
        let bytes = [UInt8](data)
        var best: (encoding: TextEncoding, score: Double)? = nil
        var korean: (score: Double, spaces: Int, characters: Int)? = nil
        for candidate in preferred + [gb18030, big5, shiftJIS, eucJP, eucKR] {
            let result = legacyScore(bytes, as: candidate)
            guard result.characters > 0, canDecode(candidate) else { continue }
            if candidate.id == "euc-kr" { korean = result }
            if best == nil || result.score > best!.score + 0.0001 { best = (candidate, result.score) }
        }
        guard let best, best.score >= 0.5 else { return nil }
        // Hangul and the frequent Chinese characters share the same byte range. Korean separates its
        // words with spaces and stays entirely inside the hangul rows; Chinese does neither.
        if best.encoding.id == "gb18030", let korean, korean.score >= best.score - 0.02, korean.spaces * 8 >= korean.characters, canDecode(eucKR) {
            return eucKR
        }
        return best.encoding
    }
}
