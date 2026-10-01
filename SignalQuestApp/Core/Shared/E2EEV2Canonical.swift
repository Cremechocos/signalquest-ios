import Foundation
import CryptoKit

// Briques communes des formats du jalon A (spec E2EE, annexe D.0) : JSON
// canonique strict, signatures ECDSA en forme low-S, chaînes canoniques et
// condensats de liste. Aucune dépendance réseau, trousseau ni interface.

/// Valeur JSON des nouveaux formats v2. Pas de nombre : les entiers voyagent en
/// chaînes décimales (spec §15), ce qui évite les écarts de sérialisation.
indirect enum E2EEV2JSON: Equatable, Sendable {
    case string(String)
    case array([E2EEV2JSON])
    case object([String: E2EEV2JSON])
    case bool(Bool)
    case null

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [E2EEV2JSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: E2EEV2JSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

enum E2EEV2CanonicalJSONError: Error, Equatable {
    case invalidSyntax
    case duplicateKey
    case unsupportedNumber
    case loneSurrogate
    case notCanonical
    case tooDeep
}

/// JSON canonique RFC 8785, réduit aux types de `E2EEV2JSON`, et analyseur
/// strict : clés dupliquées, nombres, substituts isolés et formes non
/// canoniques sont refusés. `JSONSerialization` accepte les clés dupliquées :
/// il ne convient pas pour ces formats.
enum E2EEV2CanonicalJSON {
    static let maxDepth = 32

    static func encode(_ value: E2EEV2JSON) -> Data {
        var out = Data()
        write(value, into: &out)
        return out
    }

    static func encodeString(_ value: E2EEV2JSON) -> String {
        String(decoding: encode(value), as: UTF8.self)
    }

    /// Analyse stricte puis exige que l'entrée soit déjà canonique, octet pour
    /// octet (un document signé voyage tel quel, annexe D.0).
    static func parseCanonical(_ data: Data) throws -> E2EEV2JSON {
        var parser = Parser(bytes: Array(data))
        let value = try parser.parseDocument()
        guard encode(value) == data else { throw E2EEV2CanonicalJSONError.notCanonical }
        return value
    }

    static func parseCanonical(_ text: String) throws -> E2EEV2JSON {
        try parseCanonical(Data(text.utf8))
    }

    /// Analyse stricte d'une réponse du serveur : clés dupliquées, nombres et
    /// substituts isolés refusés, sans exiger l'ordre canonique des clés.
    static func parseStrict(_ data: Data) throws -> E2EEV2JSON {
        var parser = Parser(bytes: Array(data))
        return try parser.parseDocument()
    }

    private static func write(_ value: E2EEV2JSON, into out: inout Data) {
        switch value {
        case .null:
            out.append(contentsOf: Array("null".utf8))
        case .bool(let flag):
            out.append(contentsOf: Array((flag ? "true" : "false").utf8))
        case .string(let text):
            writeString(text, into: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                write(item, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let members):
            out.append(UInt8(ascii: "{"))
            // RFC 8785 §3.2.3 : tri par unités de code UTF-16.
            let keys = members.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            for (index, key) in keys.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                writeString(key, into: &out)
                out.append(UInt8(ascii: ":"))
                write(members[key] ?? .null, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func writeString(_ text: String, into out: inout Data) {
        out.append(UInt8(ascii: "\""))
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append(contentsOf: Array("\\\"".utf8))
            case 0x5C: out.append(contentsOf: Array("\\\\".utf8))
            case 0x08: out.append(contentsOf: Array("\\b".utf8))
            case 0x09: out.append(contentsOf: Array("\\t".utf8))
            case 0x0A: out.append(contentsOf: Array("\\n".utf8))
            case 0x0C: out.append(contentsOf: Array("\\f".utf8))
            case 0x0D: out.append(contentsOf: Array("\\r".utf8))
            case 0x00..<0x20:
                out.append(contentsOf: Array(String(format: "\\u%04x", scalar.value).utf8))
            default:
                out.append(contentsOf: Array(String(scalar).utf8))
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func parseDocument() throws -> E2EEV2JSON {
            skipWhitespace()
            let value = try parseValue(depth: 0)
            skipWhitespace()
            guard index == bytes.count else { throw E2EEV2CanonicalJSONError.invalidSyntax }
            return value
        }

        private mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        private mutating func parseValue(depth: Int) throws -> E2EEV2JSON {
            guard depth <= E2EEV2CanonicalJSON.maxDepth else { throw E2EEV2CanonicalJSONError.tooDeep }
            guard index < bytes.count else { throw E2EEV2CanonicalJSONError.invalidSyntax }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                throw E2EEV2CanonicalJSONError.unsupportedNumber
            default:
                throw E2EEV2CanonicalJSONError.invalidSyntax
            }
        }

        private mutating func expect(_ literal: String) throws {
            let expected = Array(literal.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected else {
                throw E2EEV2CanonicalJSONError.invalidSyntax
            }
            index += expected.count
        }

        private mutating func parseObject(depth: Int) throws -> E2EEV2JSON {
            index += 1
            var members: [String: E2EEV2JSON] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                    throw E2EEV2CanonicalJSONError.invalidSyntax
                }
                let key = try parseString()
                guard members[key] == nil else { throw E2EEV2CanonicalJSONError.duplicateKey }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                    throw E2EEV2CanonicalJSONError.invalidSyntax
                }
                index += 1
                skipWhitespace()
                members[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                guard index < bytes.count else { throw E2EEV2CanonicalJSONError.invalidSyntax }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw E2EEV2CanonicalJSONError.invalidSyntax
            }
        }

        private mutating func parseArray(depth: Int) throws -> E2EEV2JSON {
            index += 1
            var items: [E2EEV2JSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw E2EEV2CanonicalJSONError.invalidSyntax }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw E2EEV2CanonicalJSONError.invalidSyntax
            }
        }

        private mutating func parseString() throws -> String {
            index += 1
            var raw: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    guard let text = String(bytes: raw, encoding: .utf8) else {
                        throw E2EEV2CanonicalJSONError.invalidSyntax
                    }
                    return text
                }
                guard byte >= 0x20 else { throw E2EEV2CanonicalJSONError.invalidSyntax }
                if byte != UInt8(ascii: "\\") {
                    raw.append(byte)
                    index += 1
                    continue
                }
                index += 1
                guard index < bytes.count else { throw E2EEV2CanonicalJSONError.invalidSyntax }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): raw.append(0x22)
                case UInt8(ascii: "\\"): raw.append(0x5C)
                case UInt8(ascii: "/"): raw.append(0x2F)
                case UInt8(ascii: "b"): raw.append(0x08)
                case UInt8(ascii: "f"): raw.append(0x0C)
                case UInt8(ascii: "n"): raw.append(0x0A)
                case UInt8(ascii: "r"): raw.append(0x0D)
                case UInt8(ascii: "t"): raw.append(0x09)
                case UInt8(ascii: "u"):
                    let unit = try parseHex4()
                    let scalarValue: UInt32
                    if (0xD800...0xDBFF).contains(unit) {
                        guard index + 1 < bytes.count,
                              bytes[index] == UInt8(ascii: "\\"),
                              bytes[index + 1] == UInt8(ascii: "u") else {
                            throw E2EEV2CanonicalJSONError.loneSurrogate
                        }
                        index += 2
                        let low = try parseHex4()
                        guard (0xDC00...0xDFFF).contains(low) else {
                            throw E2EEV2CanonicalJSONError.loneSurrogate
                        }
                        scalarValue = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(unit) {
                        throw E2EEV2CanonicalJSONError.loneSurrogate
                    } else {
                        scalarValue = UInt32(unit)
                    }
                    guard let scalar = Unicode.Scalar(scalarValue) else {
                        throw E2EEV2CanonicalJSONError.invalidSyntax
                    }
                    raw.append(contentsOf: Array(String(scalar).utf8))
                default:
                    throw E2EEV2CanonicalJSONError.invalidSyntax
                }
            }
            throw E2EEV2CanonicalJSONError.invalidSyntax
        }

        private mutating func parseHex4() throws -> UInt16 {
            guard index + 4 <= bytes.count,
                  let text = String(bytes: bytes[index..<(index + 4)], encoding: .ascii),
                  text.allSatisfy(\.isHexDigit),
                  let value = UInt16(text, radix: 16) else {
                throw E2EEV2CanonicalJSONError.invalidSyntax
            }
            index += 4
            return value
        }
    }
}

enum E2EEV2SignatureError: Error, Equatable {
    case invalidSignature
    case highS
}

/// Signatures ECDSA P-256 des formats v2 : DER, forme low-S obligatoire
/// (spec §4.1 et §15). CryptoKit signe avec un aléa et accepte le high-S : on
/// normalise à la signature et on refuse le high-S à la vérification.
enum E2EEV2LowS {
    /// Ordre de la courbe P-256, big-endian.
    static let curveOrder: [UInt8] = hexBytes("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
    /// Partie entière de l'ordre divisé par deux.
    static let halfOrder: [UInt8] = hexBytes("7fffffff800000007fffffffffffffffde737d56d38bcf4279dce5617e3192a8")

    static func sign(_ message: Data, with key: P256.Signing.PrivateKey) throws -> Data {
        try normalize(der: try key.signature(for: message).derRepresentation)
    }

    /// DER canonique exigé : la signature doit se réencoder à l'identique,
    /// sans zéro de tête superflu ni octet en trop, faute de quoi deux
    /// encodages d'une même signature passeraient.
    static func verify(derSignature: Data, message: Data, publicKey: P256.Signing.PublicKey) -> Bool {
        guard isLowS(der: derSignature),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: derSignature),
              signature.derRepresentation == derSignature else {
            return false
        }
        return publicKey.isValidSignature(signature, for: message)
    }

    static func isLowS(der: Data) -> Bool {
        guard let raw = try? P256.Signing.ECDSASignature(derRepresentation: der).rawRepresentation,
              raw.count == 64 else {
            return false
        }
        return compare(Array(raw.suffix(32)), halfOrder) <= 0
    }

    /// Remplace `s` par `n − s` si `s` dépasse la moitié de l'ordre : la
    /// signature reste valide, sous sa forme canonique.
    static func normalize(der: Data) throws -> Data {
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: der) else {
            throw E2EEV2SignatureError.invalidSignature
        }
        let raw = signature.rawRepresentation
        let r = Array(raw.prefix(32))
        let s = Array(raw.suffix(32))
        guard compare(s, halfOrder) > 0 else { return signature.derRepresentation }
        let lowS = subtract(curveOrder, s)
        return try P256.Signing.ECDSASignature(rawRepresentation: Data(r + lowS)).derRepresentation
    }

    /// Même signature en forme high-S : sert aux vecteurs négatifs.
    static func highSVariant(der: Data) throws -> Data {
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: der) else {
            throw E2EEV2SignatureError.invalidSignature
        }
        let raw = signature.rawRepresentation
        let r = Array(raw.prefix(32))
        let s = Array(raw.suffix(32))
        guard compare(s, halfOrder) <= 0 else { return signature.derRepresentation }
        return try P256.Signing.ECDSASignature(rawRepresentation: Data(r + subtract(curveOrder, s))).derRepresentation
    }

    private static func compare(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        for (a, b) in zip(lhs, rhs) where a != b { return a < b ? -1 : 1 }
        return 0
    }

    private static func subtract(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: lhs.count)
        var borrow = 0
        for position in stride(from: lhs.count - 1, through: 0, by: -1) {
            var value = Int(lhs[position]) - Int(rhs[position]) - borrow
            borrow = value < 0 ? 1 : 0
            if value < 0 { value += 256 }
            result[position] = UInt8(value)
        }
        return result
    }

    private static func hexBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }
}

/// Chaînes canoniques et condensats communs (annexe D.0).
enum E2EEV2Canonical {
    static let opaquePattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}\z"#
    static let decimalPattern = #"^(0|[1-9][0-9]{0,18})\z"#

    static func line(_ fields: [String]) -> Data {
        Data(fields.joined(separator: "\n").utf8)
    }

    /// Découpe stricte d'une chaîne signée : nombre exact de champs et
    /// étiquette attendue en tête, sans jamais reconstruire depuis des champs.
    static func split(_ canonical: String, tag: String, version: String, fieldCount: Int) -> [String]? {
        let fields = canonical.components(separatedBy: "\n")
        guard fields.count == fieldCount, fields.first == tag, fields.dropFirst().first == version else {
            return nil
        }
        return fields
    }

    static func isOpaque(_ value: String) -> Bool {
        value.range(of: opaquePattern, options: .regularExpression) != nil
    }

    static func isDecimal(_ value: String) -> Bool {
        value.range(of: decimalPattern, options: .regularExpression) != nil
    }

    /// Plus grand numéro d'époque ou de changement accepté (2³¹ − 2), comme pour
    /// les versions de liste (D.3) : `n + 1` ne déborde jamais.
    static let maxSequenceNumber = 2_147_483_646

    /// Numéro décimal canonique de 1 à `maxSequenceNumber`.
    static func sequenceNumber(_ value: String) -> Int? {
        guard isDecimal(value), let number = Int(value), (1...maxSequenceNumber).contains(number) else { return nil }
        return number
    }

    /// Plus grand instant (ms) ou séquence du serveur accepté : 2⁵³ − 1, entier
    /// exact en JavaScript. Une durée ajoutée ne fait jamais déborder un Int64.
    static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    /// Décimal canonique de 0 à `maxSafeInteger`.
    static func safeInteger(_ value: String) -> Int64? {
        guard isDecimal(value), let number = Int64(value), number <= maxSafeInteger else { return nil }
        return number
    }

    static func base64URL(_ data: Data) -> String {
        data.base64URLEncodedNoPadding()
    }

    static func sha256B64URL(_ data: Data) -> String {
        base64URL(Data(SHA256.hash(data: data)))
    }

    /// `b64url(SHA-256("<étiquette>\n1" ‖ ("\n" ‖ ligne)*))`, lignes triées dans
    /// l'ordre des octets UTF-8.
    static func listDigest(tag: String, lines: [String]) -> String {
        let sorted = lines.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        return sha256B64URL(line([tag, "1"] + sorted))
    }

    /// Empreinte d'appareil : `b64url(SHA-256(identityKey ‖ signingKey))`.
    static func deviceFingerprint(identityKeyX963: Data, signingKeyX963: Data) -> String {
        sha256B64URL(identityKeyX963 + signingKeyX963)
    }

    /// Clé publique P-256 en base64 canonique : `Data(base64Encoded:)` accepte
    /// aussi des variantes (`QR==` comme `QQ==`), qu'une comparaison de chaînes
    /// prendrait pour une autre clé.
    static func isX963PublicKey(_ b64: String) -> Bool {
        guard let data = Data(base64Encoded: b64), data.count == 65, data.first == 0x04,
              data.base64EncodedString() == b64 else { return false }
        return (try? P256.Signing.PublicKey(x963Representation: data)) != nil
    }
}
