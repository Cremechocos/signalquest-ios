import Foundation

/// Efface le lieu d'une image ou d'une vidéo en écrasant des octets par des zéros, sans
/// rien réencoder ni déplacer : taille, pixels, orientation, date, modèle, gain map HDR et
/// vidéo d'une Motion Photo restent (décision d'Alexandre du 04/11, « Nettoyer, tout
/// garder », E2EE-AUTO §7.7). Mêmes plages que `MediaLocationScrubber.kt` d'Android, pour
/// qu'une photo sorte pareille des deux apps :
/// - Exif : le bloc GPS seul (compte, entrées, valeurs hors entrée) ; le pointeur 0x8825 reste ;
///   la valeur des tags XMP (700, 0x02BC) et IPTC (33723, 0x83BB) de tout IFD, comme le XMP partout ailleurs ;
///   les sous-IFD (Exif 0x8769, Interop 0xA005, SubIFDs 0x014A) reçoivent le même traitement ;
/// - XMP, XMP étendu, IPTC (APP13) : tout le contenu après l'identifiant ;
/// - ISO BMFF : la valeur de `©xyz` et de `com.apple.quicktime.location.ISO6709`, et le bloc
///   GPS de l'item Exif d'un HEIF, tout le corps de son item XMP (`mime`, `application/rdf+xml`) ;
/// - TIFF : ce même traitement dans chaque IFD de la chaîne (une page chacun) ;
/// - PNG : le bloc GPS de `eXIf`, et ce qui suit le mot-clé `XML:com.adobe.xmp` d'un `iTXt`,
///   `tEXt` ou `zTXt` (flux zlib remplacé par un flux stocké d'espaces de même longueur),
///   CRC recalculé ; les textes d'un autre mot-clé restent ;
/// - WebP : le bloc GPS du chunk `EXIF`, tout le chunk `XMP ` ; GIF : les données de
///   l'extension `XMP DataXMP`, jamais les octets de longueur de ses sous-blocs ;
/// - ce qui suit l'image principale d'un JPEG (autre JPEG, vidéo) : traité de même, 4 images au plus.
/// Une structure illisible arrête le parcours là où il en est, sans refuser l'envoi.
/// Limite acceptée (Alexandre, 04/11) : la 5e image d'un JPEG et ce qui suit partent tels quels.
enum MediaLocationScrubber {
    /// Images d'un même fichier traitées au plus (l'image principale et ce qui la suit).
    static let maxImages = 4
    static let maxBoxDepth = 8
    /// IFD distincts lus au plus dans un en-tête TIFF, pages, sous-IFD et IFD GPS compris ; les
    /// IFD déjà vus ne sont pas relus, ce qui règle les boucles d'un fichier malformé.
    static let maxTotalIFDs = 256

    /// Ce que le nettoyage change : plages mises à zéro, flux remplacés, chunks PNG dont
    /// le CRC est à recalculer.
    struct Plan: Equatable {
        var zeroed: [Range<Int>] = []
        var replaced: [(offset: Int, bytes: [UInt8])] = []
        var pngChunks: [Range<Int>] = []

        var isEmpty: Bool { zeroed.isEmpty && replaced.isEmpty }

        static func == (lhs: Plan, rhs: Plan) -> Bool {
            lhs.zeroed == rhs.zeroed && lhs.pngChunks == rhs.pngChunks
                && lhs.replaced.map(\.offset) == rhs.replaced.map(\.offset) && lhs.replaced.map(\.bytes) == rhs.replaced.map(\.bytes)
        }
    }

    static func scrubbed(_ data: Data) -> Data {
        let plan = plan(for: data)
        guard !plan.isEmpty else { return data }
        var bytes = [UInt8](data)
        for range in plan.zeroed {
            for index in range where index < bytes.count { bytes[index] = 0 }
        }
        for replacement in plan.replaced where replacement.offset + replacement.bytes.count <= bytes.count {
            bytes.replaceSubrange(replacement.offset ..< replacement.offset + replacement.bytes.count, with: replacement.bytes)
        }
        // Chunk PNG : CRC-32 sur le type et les données, rangé juste après.
        for chunk in plan.pngChunks where chunk.upperBound + 4 <= bytes.count {
            let crc = crc32(bytes[chunk])
            for shift in 0..<4 { bytes[chunk.upperBound + shift] = UInt8(truncatingIfNeeded: crc >> (24 - 8 * UInt32(shift))) }
        }
        return Data(bytes)
    }

    static func plan(for data: Data) -> Plan {
        let bytes = [UInt8](data)
        var plan = Plan()
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            var images = 0
            scanJPEG(bytes, at: 0, images: &images, into: &plan.zeroed)
        } else if bytes.count >= 8, Array(bytes[4..<8]) == Array("ftyp".utf8) {
            scanBoxes(bytes, from: 0, to: bytes.count, depth: 0, into: &plan.zeroed)
        } else if hasPrefix(bytes, [0x49, 0x49, 0x2A, 0x00], at: 0) || hasPrefix(bytes, [0x4D, 0x4D, 0x00, 0x2A], at: 0) {
            gpsRanges(bytes, tiff: 0, end: bytes.count, into: &plan.zeroed)
        } else if hasPrefix(bytes, pngSignature, at: 0) {
            scanPNG(bytes, into: &plan)
        } else if hasPrefix(bytes, Array("RIFF".utf8), at: 0), hasPrefix(bytes, Array("WEBP".utf8), at: 8) {
            scanWebP(bytes, into: &plan.zeroed)
        } else if hasPrefix(bytes, Array("GIF87a".utf8), at: 0) || hasPrefix(bytes, Array("GIF89a".utf8), at: 0) {
            scanGIF(bytes, into: &plan.zeroed)
        }
        // Une même plage atteinte deux fois (deux IFD vers un même bloc GPS) n'en fait qu'une,
        // dans l'ordre du fichier : les plans se comparent à ceux d'Android.
        var seen: Set<[Int]> = []
        plan.zeroed = plan.zeroed.filter { !$0.isEmpty && seen.insert([$0.lowerBound, $0.upperBound]).inserted }
            .sorted { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) }
        return plan
    }

    // MARK: JPEG

    private static let exifMagic = Array("Exif\0\0".utf8)
    private static let xmpMagic = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
    private static let xmpExtensionMagic = Array("http://ns.adobe.com/xmp/extension/\0".utf8)
    private static let photoshopMagic = Array("Photoshop 3.0\0".utf8)

    private static func scanJPEG(_ bytes: [UInt8], at start: Int, images: inout Int, into ranges: inout [Range<Int>]) {
        guard images < maxImages else { return }
        images += 1
        var index = start + 2
        while index + 3 < bytes.count {
            guard bytes[index] == 0xFF else { return }
            let marker = bytes[index + 1]
            if marker == 0xFF { index += 1; continue }
            // Début des données compressées, ou fin de l'image : la suite du fichier.
            if marker == 0xDA || marker == 0xD9 {
                scanTrailer(bytes, from: index, images: &images, into: &ranges)
                return
            }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { index += 2; continue }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let payload = index + 4
            let end = index + 2 + length
            guard length >= 2, end <= bytes.count else { return }
            // L'identifiant doit tenir dans le segment, pas seulement dans le fichier.
            func starts(with magic: [UInt8]) -> Bool { payload + magic.count <= end && hasPrefix(bytes, magic, at: payload) }
            if marker == 0xE1, starts(with: exifMagic) {
                gpsRanges(bytes, tiff: payload + exifMagic.count, end: end, into: &ranges)
            } else if marker == 0xE1, starts(with: xmpMagic) {
                ranges.append(payload + xmpMagic.count ..< end)
            } else if marker == 0xE1, starts(with: xmpExtensionMagic) {
                ranges.append(payload + xmpExtensionMagic.count ..< end)
            } else if marker == 0xED, starts(with: photoshopMagic) {
                ranges.append(payload + photoshopMagic.count ..< end)
            }
            index = end
        }
    }

    /// Après le SOS ou l'EOI : le premier JPEG (`FFD8FF`, jamais présent dans des données
    /// compressées, où un `FF` est suivi de `00` ou d'un RST) ou la première boîte `ftyp`
    /// dont la taille tient dans le fichier. Rien ne se cherche après une vidéo.
    private static func scanTrailer(_ bytes: [UInt8], from start: Int, images: inout Int, into ranges: inout [Range<Int>]) {
        guard images < maxImages else { return }
        let jpeg = firstIndex(of: [0xFF, 0xD8, 0xFF], in: bytes, from: start + 2)
        var video: Int?
        var search = start + 2
        while let found = firstIndex(of: Array("ftyp".utf8), in: bytes, from: search) {
            let boxStart = found - 4
            if boxStart >= start + 2, let size = uint32(bytes, at: boxStart), size >= 8, size <= bytes.count - boxStart {
                video = boxStart
                break
            }
            search = found + 1
        }
        switch (jpeg, video) {
        case let (jpeg?, video?) where video < jpeg:
            scanBoxes(bytes, from: video, to: bytes.count, depth: 0, into: &ranges)
        case let (jpeg?, _):
            scanJPEG(bytes, at: jpeg, images: &images, into: &ranges)
        case let (nil, video?):
            scanBoxes(bytes, from: video, to: bytes.count, depth: 0, into: &ranges)
        case (nil, nil):
            return
        }
    }

    // MARK: Exif (TIFF)

    /// Le lieu d'un en-tête TIFF, dans chaque IFD de la chaîne et dans leurs sous-IFD : le bloc
    /// GPS pointé (son compte d'entrées, ses entrées, et les valeurs rangées hors des entrées :
    /// une latitude, trois rationnels, 24 octets), et la valeur entière des tags XMP et IPTC.
    /// Les IFD restent. Le champ « IFD suivant » d'un sous-IFD n'est pas suivi.
    static func gpsRanges(_ bytes: [UInt8], tiff: Int, end: Int, into ranges: inout [Range<Int>]) {
        guard tiff + 8 <= end, end <= bytes.count else { return }
        let littleEndian: Bool
        switch (bytes[tiff], bytes[tiff + 1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: return
        }
        func u16(_ at: Int) -> Int? {
            guard at >= tiff, at + 2 <= end else { return nil }
            return littleEndian ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : Int(bytes[at]) << 8 | Int(bytes[at + 1])
        }
        func u32(_ at: Int) -> Int? {
            guard at >= tiff, at + 4 <= end else { return nil }
            let b = bytes[at..<at + 4].map(Int.init)
            return littleEndian ? b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24 : b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
        }
        var visited: Set<Int> = []
        /// Traite un IFD et ses sous-IFD ; rend le décalage de l'IFD suivant de la chaîne. Un IFD
        /// GPS est un sous-IFD comme les autres (même budget), effacé en plus.
        func walk(_ offset: Int, isGPS: Bool = false) -> Int? {
            guard offset != 0, visited.count < maxTotalIFDs, visited.insert(offset).inserted,
                  let count = u16(tiff + offset) else { return nil }
            if isGPS { gpsBlock(bytes, tiff: tiff, gps: tiff + offset, end: end, u16: u16, u32: u32, into: &ranges) }
            var children: [(offset: Int, isGPS: Bool)] = []
            for entry in 0..<count {
                let at = tiff + offset + 2 + entry * 12
                guard let tag = u16(at) else { break }
                switch tag {
                case 0x8825:
                    if let gps = u32(at + 8) { children.append((gps, true)) }
                case 0x02BC, 0x83BB:
                    if let value = valueRange(at: at, tiff: tiff, end: end, u16: u16, u32: u32) { ranges.append(value) }
                case 0x8769, 0xA005, 0x014A:
                    // LONG ou IFD : un décalage dans l'entrée, ou un tableau de décalages ailleurs.
                    guard let type = u16(at + 2), type == 4 || type == 13, let n = u32(at + 4), n > 0, n <= maxTotalIFDs,
                          let first = u32(at + 8) else { continue }
                    if n == 1 {
                        children.append((first, false))
                    } else {
                        for index in 0..<n { if let child = u32(tiff + first + 4 * index) { children.append((child, false)) } }
                    }
                default:
                    break
                }
            }
            for child in children { _ = walk(child.offset, isGPS: child.isGPS) }
            return u32(tiff + offset + 2 + count * 12)
        }
        // Chaque IFD de la chaîne finit par le décalage du suivant, 0 en fin de chaîne.
        var next = u32(tiff + 4)
        while let offset = next { next = walk(offset) }
    }

    private static func gpsBlock(_ bytes: [UInt8], tiff: Int, gps: Int, end: Int, u16: (Int) -> Int?, u32: (Int) -> Int?,
                                 into ranges: inout [Range<Int>]) {
        guard let count = u16(gps), gps + 2 + count * 12 <= end else { return }
        ranges.append(gps ..< gps + 2)
        if count > 0 { ranges.append(gps + 2 ..< gps + 2 + count * 12) }
        for entry in 0..<count {
            let at = gps + 2 + entry * 12
            // Les valeurs de 4 octets au plus sont dans l'entrée, déjà effacée.
            if let value = valueRange(at: at, tiff: tiff, end: end, u16: u16, u32: u32), value.lowerBound != at + 8 {
                ranges.append(value)
            }
        }
    }

    private static let typeSizes = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4]

    /// Valeur d'une entrée d'IFD : dans l'entrée elle-même jusqu'à 4 octets, sinon à son décalage.
    private static func valueRange(at entry: Int, tiff: Int, end: Int, u16: (Int) -> Int?, u32: (Int) -> Int?) -> Range<Int>? {
        guard let type = u16(entry + 2), let valueCount = u32(entry + 4), let size = typeSizes[type] else { return nil }
        let length = size * valueCount
        guard length > 0 else { return nil }
        if length <= 4 { return entry + 8 + length <= end ? entry + 8 ..< entry + 8 + length : nil }
        guard let valueOffset = u32(entry + 8) else { return nil }
        let value = tiff + valueOffset
        guard value >= tiff, value + length <= end else { return nil }
        return value ..< value + length
    }

    // MARK: ISO BMFF

    private static let containers: Set<String> = ["moov", "udta", "trak", "mdia", "minf", "stbl", "edts", "moof", "traf"]
    private static let isoLocationKey = "com.apple.quicktime.location.ISO6709"

    private static func scanBoxes(_ bytes: [UInt8], from start: Int, to end: Int, depth: Int, into ranges: inout [Range<Int>]) {
        guard depth <= maxBoxDepth else { return }
        var index = start
        while index + 8 <= end {
            guard let box = box(bytes, at: index, end: end) else { return }
            switch box.type {
            case let type where containers.contains(type):
                scanBoxes(bytes, from: box.body, to: box.end, depth: depth + 1, into: &ranges)
            case "\u{A9}xyz":
                ranges.append(box.body ..< box.end)
            case "meta":
                scanMeta(bytes, box, depth: depth + 1, into: &ranges)
            default:
                break
            }
            index = box.end
        }
    }

    private struct Box {
        let type: String
        let start: Int
        let body: Int
        let end: Int
    }

    /// Taille sur 32 bits, `1` (64 bits après le type) ou `0` (jusqu'à la fin du conteneur).
    private static func box(_ bytes: [UInt8], at start: Int, end: Int) -> Box? {
        guard start + 8 <= end, let size = uint32(bytes, at: start) else { return nil }
        let type = fourCC(bytes, at: start + 4)
        var body = start + 8
        let boxEnd: Int
        switch size {
        case 0:
            boxEnd = end
        case 1:
            guard start + 16 <= end else { return nil }
            var large = 0
            for byte in bytes[start + 8..<start + 16] {
                guard large <= Int.max >> 8 else { return nil }
                large = large << 8 | Int(byte)
            }
            body = start + 16
            boxEnd = start + large
        default:
            boxEnd = start + size
        }
        guard boxEnd >= body, boxEnd <= end else { return nil }
        return Box(type: type, start: start, body: body, end: boxEnd)
    }

    /// `meta` d'ISO BMFF (FullBox : version et drapeaux d'abord) ou de QuickTime (sans) :
    /// une boîte plausible suit-elle les 4 octets de version et drapeaux ?
    private static func scanMeta(_ bytes: [UInt8], _ meta: Box, depth: Int, into ranges: inout [Range<Int>]) {
        guard depth <= maxBoxDepth else { return }
        let first = meta.body + 4 + 4 <= meta.end && isPlausibleType(bytes, at: meta.body + 8) ? meta.body + 4 : meta.body
        var children: [Box] = []
        var index = first
        while index + 8 <= meta.end, let child = box(bytes, at: index, end: meta.end) {
            children.append(child)
            index = child.end
        }
        // `keys` d'abord : l'index de la clé de lieu, puis sa valeur dans `ilst`.
        if let keys = children.first(where: { $0.type == "keys" }), let locationIndex = keyIndex(bytes, keys),
           let ilst = children.first(where: { $0.type == "ilst" }) {
            var item = ilst.body
            while item + 8 <= ilst.end, let entry = box(bytes, at: item, end: ilst.end) {
                if uint32(bytes, at: entry.start + 4) == locationIndex {
                    var inner = entry.body
                    while inner + 8 <= entry.end, let data = box(bytes, at: inner, end: entry.end) {
                        if data.type == "data", data.start + 16 <= data.end { ranges.append(data.start + 16 ..< data.end) }
                        inner = data.end
                    }
                }
                item = entry.end
            }
        }
        for child in children where child.type == "udta" {
            scanBoxes(bytes, from: child.body, to: child.end, depth: depth + 1, into: &ranges)
        }
        guard let iinf = children.first(where: { $0.type == "iinf" }), let iloc = children.first(where: { $0.type == "iloc" }) else { return }
        let items = itemIds(bytes, iinf)
        if let xmp = items.xmp {
            ranges += itemExtents(bytes, iloc, itemId: xmp)
        }
        // Le corps de l'item Exif, ses étendues mises bout à bout, commence par 4 octets : le
        // décalage vers l'en-tête TIFF. Les plages trouvées sont reportées sur le fichier.
        guard let exif = items.exif else { return }
        let extents = itemExtents(bytes, iloc, itemId: exif)
        let body = extents.flatMap { bytes[$0] }
        guard body.count >= 4, let shift = uint32(body, at: 0) else { return }
        var bodyRanges: [Range<Int>] = []
        gpsRanges(body, tiff: 4 + shift, end: body.count, into: &bodyRanges)
        for range in bodyRanges {
            var start = 0
            for extent in extents {
                let lower = max(range.lowerBound, start), upper = min(range.upperBound, start + extent.count)
                if lower < upper {
                    ranges.append(extent.lowerBound + lower - start ..< extent.lowerBound + upper - start)
                }
                start += extent.count
            }
        }
    }

    /// Index (à partir de 1) de la clé de lieu dans `keys` : version et drapeaux, nombre,
    /// puis chaque clé (taille, espace de noms, valeur).
    private static func keyIndex(_ bytes: [UInt8], _ keys: Box) -> Int? {
        guard let count = uint32(bytes, at: keys.body + 4) else { return nil }
        var index = keys.body + 8
        for number in 1...max(1, count) where count > 0 {
            guard let size = uint32(bytes, at: index), size >= 8, index + size <= keys.end else { return nil }
            if String(decoding: bytes[index + 8..<index + size], as: UTF8.self) == isoLocationKey { return number }
            index += size
        }
        return nil
    }

    /// Identifiants des items `Exif` et XMP de `iinf`. `infe` version 2 (16 bits) ou 3
    /// (32 bits) : version et drapeaux, identifiant, protection, type, `item_name` terminé
    /// par un zéro (souvent vide), puis pour un type `mime` seulement, `content_type`.
    private static func itemIds(_ bytes: [UInt8], _ iinf: Box) -> (exif: Int?, xmp: Int?) {
        var result: (exif: Int?, xmp: Int?) = (nil, nil)
        guard iinf.body + 4 <= iinf.end else { return result }
        let version = bytes[iinf.body]
        var index = iinf.body + 4 + (version == 0 ? 2 : 4)
        /// Fin (exclue) de la chaîne terminée par un zéro qui commence à `start`.
        func cString(from start: Int, end: Int) -> Range<Int>? {
            var at = start
            while at < end { if bytes[at] == 0 { return start ..< at }; at += 1 }
            return nil
        }
        while index + 8 <= iinf.end, let infe = box(bytes, at: index, end: iinf.end) {
            if infe.type == "infe", infe.body + 4 <= infe.end, bytes[infe.body] >= 2 {
                let idSize = bytes[infe.body] >= 3 ? 4 : 2
                let typeAt = infe.body + 4 + idSize + 2
                let id = idSize == 4 ? uint32(bytes, at: infe.body + 4) : uint16(bytes, at: infe.body + 4)
                if typeAt + 4 <= infe.end, let id {
                    switch fourCC(bytes, at: typeAt) {
                    case "Exif":
                        result.exif = result.exif ?? id
                    case "mime":
                        if let name = cString(from: typeAt + 4, end: infe.end),
                           let contentType = cString(from: name.upperBound + 1, end: infe.end),
                           Array(bytes[contentType]) == Array("application/rdf+xml".utf8) {
                            result.xmp = result.xmp ?? id
                        }
                    default:
                        break
                    }
                }
            }
            index = infe.end
        }
        return result
    }

    /// Étendues de l'item dans `iloc`, méthode de construction 0 seulement :
    /// `base_offset + extent_offset`, de longueur `extent_length`.
    private static func itemExtents(_ bytes: [UInt8], _ iloc: Box, itemId: Int) -> [Range<Int>] {
        var at = iloc.body
        guard at + 6 <= iloc.end else { return [] }
        let version = bytes[at]
        at += 4
        let offsetSize = Int(bytes[at] >> 4), lengthSize = Int(bytes[at] & 0x0F)
        let baseOffsetSize = Int(bytes[at + 1] >> 4)
        let indexSize = version == 1 || version == 2 ? Int(bytes[at + 1] & 0x0F) : 0
        at += 2
        func read(_ size: Int) -> Int? {
            guard size == 0 || [2, 4, 8].contains(size), at + size <= iloc.end else { return nil }
            var value = 0
            for byte in bytes[at..<at + size] { value = value << 8 | Int(byte) }
            at += size
            return value
        }
        guard let itemCount = read(version < 2 ? 2 : 4) else { return [] }
        for _ in 0..<itemCount {
            guard let id = read(version < 2 ? 2 : 4) else { return [] }
            var method = 0
            if version == 1 || version == 2 { guard let field = read(2) else { return [] }; method = field & 0x0F }
            guard read(2) != nil, let baseOffset = read(baseOffsetSize), let extentCount = read(2) else { return [] }
            var extents: [Range<Int>] = []
            for _ in 0..<extentCount {
                if indexSize > 0 { guard read(indexSize) != nil else { return [] } }
                guard let offset = read(offsetSize), let length = read(lengthSize) else { return [] }
                extents.append(baseOffset + offset ..< baseOffset + offset + length)
            }
            if id == itemId {
                guard method == 0, extents.allSatisfy({ $0.lowerBound < $0.upperBound && $0.upperBound <= bytes.count }) else { return [] }
                return extents
            }
        }
        return []
    }

    // MARK: PNG

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let xmpKeyword = Array("XML:com.adobe.xmp".utf8)

    private static func scanPNG(_ bytes: [UInt8], into plan: inout Plan) {
        var index = pngSignature.count
        while index + 12 <= bytes.count, let length = uint32(bytes, at: index) {
            let type = fourCC(bytes, at: index + 4)
            let data = index + 8
            let end = data + length
            guard end + 4 <= bytes.count else { return }
            let before = plan.zeroed.count + plan.replaced.count
            switch type {
            case "eXIf":
                gpsRanges(bytes, tiff: data, end: end, into: &plan.zeroed)
            case "iTXt", "tEXt", "zTXt":
                guard hasPrefix(bytes, xmpKeyword + [0], at: data), data + xmpKeyword.count + 1 <= end else { break }
                let afterKeyword = data + xmpKeyword.count + 1
                if type == "zTXt" {
                    // L'octet de méthode reste ; des zéros ne feraient pas un flux zlib valide.
                    if afterKeyword + 1 < end, let stream = storedZlibStream(ofLength: end - afterKeyword - 1) {
                        plan.replaced.append((afterKeyword + 1, stream))
                    }
                } else if afterKeyword < end {
                    plan.zeroed.append(afterKeyword ..< end)
                }
            case "IEND":
                return
            default:
                break
            }
            if plan.zeroed.count + plan.replaced.count != before { plan.pngChunks.append(index + 4 ..< end) }
            index = end + 4
        }
    }

    /// Flux zlib valide de `length` octets : en-tête, blocs stockés d'espaces, Adler-32.
    static func storedZlibStream(ofLength length: Int) -> [UInt8]? {
        let maxBlock = 65_535
        // Le moins de blocs possible : chacun coûte 5 octets d'en-tête.
        var blocks = 1
        while length - 6 - 5 * blocks > blocks * maxBlock { blocks += 1 }
        var remaining = length - 6 - 5 * blocks
        guard remaining >= 0 else { return nil }
        var stream: [UInt8] = [0x78, 0x01]
        var a: UInt32 = 1, b: UInt32 = 0
        for block in 0..<blocks {
            let isLast = block == blocks - 1
            let count = isLast ? remaining : min(maxBlock, remaining)
            stream.append(isLast ? 1 : 0)
            stream += [UInt8(count & 0xFF), UInt8(count >> 8), UInt8(~count & 0xFF), UInt8((~count >> 8) & 0xFF)]
            stream += [UInt8](repeating: 0x20, count: count)
            for _ in 0..<count { a = (a + 0x20) % 65_521; b = (b + a) % 65_521 }
            remaining -= count
        }
        let adler = b << 16 | a
        stream += [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)]
        return stream.count == length ? stream : nil
    }

    static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    // MARK: WebP

    private static func scanWebP(_ bytes: [UInt8], into ranges: inout [Range<Int>]) {
        var index = 12
        while index + 8 <= bytes.count {
            let type = fourCC(bytes, at: index)
            let length = Int(bytes[index + 4]) | Int(bytes[index + 5]) << 8 | Int(bytes[index + 6]) << 16 | Int(bytes[index + 7]) << 24
            let data = index + 8
            let end = data + length
            guard end <= bytes.count else { return }
            if type == "EXIF" {
                gpsRanges(bytes, tiff: data, end: end, into: &ranges)
            } else if type == "XMP ", length > 0 {
                ranges.append(data ..< end)
            }
            index = end + (length & 1)
        }
    }

    // MARK: GIF

    private static let gifXMPIdentifier = Array("XMP DataXMP".utf8)

    private static func scanGIF(_ bytes: [UInt8], into ranges: inout [Range<Int>]) {
        guard bytes.count >= 13 else { return }
        var index = 13
        if bytes[10] & 0x80 != 0 { index += 3 << (Int(bytes[10] & 0x07) + 1) }
        /// Sous-blocs `[longueur][octets]` jusqu'au bloc vide ; rend la fin de la chaîne.
        func subBlocks(from start: Int, zeroing: Bool) -> Int? {
            var at = start
            while at < bytes.count {
                let size = Int(bytes[at])
                if size == 0 { return at + 1 }
                guard at + 1 + size <= bytes.count else { return nil }
                if zeroing { ranges.append(at + 1 ..< at + 1 + size) }
                at += 1 + size
            }
            return nil
        }
        while index < bytes.count {
            switch bytes[index] {
            case 0x21:
                guard index + 2 < bytes.count else { return }
                let label = bytes[index + 1]
                if label == 0xFF, bytes[index + 2] == 11, hasPrefix(bytes, gifXMPIdentifier, at: index + 3) {
                    guard let next = subBlocks(from: index + 3 + 11, zeroing: true) else { return }
                    index = next
                } else {
                    guard let next = subBlocks(from: index + 2, zeroing: false) else { return }
                    index = next
                }
            case 0x2C:
                guard index + 10 <= bytes.count else { return }
                var at = index + 10
                if bytes[index + 9] & 0x80 != 0 { at += 3 << (Int(bytes[index + 9] & 0x07) + 1) }
                guard let next = subBlocks(from: at + 1, zeroing: false) else { return }
                index = next
            default:
                return
            }
        }
    }

    // MARK: Octets

    /// Code de 4 octets lus un à un (`©` compris), sans décodage UTF-8.
    private static func fourCC(_ bytes: [UInt8], at index: Int) -> String {
        String(String.UnicodeScalarView(bytes[index..<index + 4].map { Unicode.Scalar($0) }))
    }

    private static func isPlausibleType(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index + 4 <= bytes.count else { return false }
        return bytes[index..<index + 4].allSatisfy { (0x20...0x7E).contains($0) || $0 == 0xA9 }
    }

    private static func hasPrefix(_ bytes: [UInt8], _ prefix: [UInt8], at index: Int) -> Bool {
        index + prefix.count <= bytes.count && Array(bytes[index..<index + prefix.count]) == prefix
    }

    private static func uint32(_ bytes: [UInt8], at index: Int) -> Int? {
        guard index >= 0, index + 4 <= bytes.count else { return nil }
        return Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16 | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
    }

    private static func uint16(_ bytes: [UInt8], at index: Int) -> Int? {
        guard index >= 0, index + 2 <= bytes.count else { return nil }
        return Int(bytes[index]) << 8 | Int(bytes[index + 1])
    }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard !pattern.isEmpty, start >= 0, bytes.count >= pattern.count else { return nil }
        var index = start
        while index + pattern.count <= bytes.count {
            if bytes[index] == pattern[0], Array(bytes[index..<index + pattern.count]) == pattern { return index }
            index += 1
        }
        return nil
    }
}
