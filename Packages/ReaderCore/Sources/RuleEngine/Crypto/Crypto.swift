import CommonCrypto
import CryptoKit
import Foundation

public enum CryptoError: Error, CustomStringConvertible {
    case invalidKey(String)
    case unsupported(String)
    case failed(String)

    public var description: String {
        switch self {
        case .invalidKey(let m): return "密钥无效：\(m)"
        case .unsupported(let m): return "不支持的算法：\(m)"
        case .failed(let m): return "加解密失败：\(m)"
        }
    }
}

/// Java 风格的 transformation，例如 `AES/CBC/PKCS5Padding`
struct CipherSpec {
    var algorithm: String
    var mode: String
    var padding: String

    init(_ transformation: String) {
        let parts = transformation.split(separator: "/").map { String($0).trimmedWhitespace }
        algorithm = (parts.first ?? "AES").uppercased()
        mode = parts.count > 1 ? parts[1].uppercased() : "ECB"
        padding = parts.count > 2 ? parts[2].uppercased() : "PKCS5PADDING"
        if algorithm == "TRIPLEDES" || algorithm == "3DES" { algorithm = "DESEDE" }
    }

    var blockSize: Int { algorithm == "AES" ? kCCBlockSizeAES128 : kCCBlockSizeDES }
}

enum SymmetricCipher {
    static func crypt(_ transformation: String, encrypt: Bool, key: Data, iv: Data?, data: Data,
                      tagLength: Int = 16, aad: Data = Data()) throws -> Data {
        let spec = CipherSpec(transformation)
        if spec.mode == "GCM" {
            return try gcm(encrypt: encrypt, key: key, iv: iv ?? Data(), data: data, tagLength: tagLength, aad: aad)
        }
        let (alg, keyData) = try algorithm(spec, key: key)
        let mode: CCMode
        switch spec.mode {
        case "ECB": mode = CCMode(kCCModeECB)
        case "CBC": mode = CCMode(kCCModeCBC)
        case "CFB": mode = CCMode(kCCModeCFB)
        case "CFB8": mode = CCMode(kCCModeCFB8)
        case "OFB": mode = CCMode(kCCModeOFB)
        case "CTR": mode = CCMode(kCCModeCTR)
        default: throw CryptoError.unsupported(transformation)
        }
        let isStream = ["CFB", "CFB8", "OFB", "CTR"].contains(spec.mode)
        // CommonCrypto 只按分组长度读取 IV，多出的字节会被静默忽略。
        // Hutool 5.8.22 + BouncyCastle 1.86（Legado 当前依赖）会直接拒绝，书源才能走进 catch。
        if ["CBC", "CFB", "CFB8", "OFB"].contains(spec.mode), let provided = iv, !provided.isEmpty,
           provided.count != spec.blockSize {
            throw CryptoError.invalidKey("\(spec.mode) 的 IV 长度为 \(provided.count)，需要 \(spec.blockSize) 字节")
        }
        var input = data
        var padding = CCPadding(ccNoPadding)
        switch spec.padding {
        case "PKCS5PADDING", "PKCS7PADDING":
            if !isStream { padding = CCPadding(ccPKCS7Padding) }
        case "ZEROPADDING":
            if encrypt, !isStream, input.count % spec.blockSize != 0 {
                input.append(Data(count: spec.blockSize - input.count % spec.blockSize))
            }
        default:
            break
        }
        let ivData: Data? = spec.mode == "ECB" ? nil : (iv.flatMap { $0.isEmpty ? nil : $0 } ?? Data(count: spec.blockSize))
        var cryptor: CCCryptorRef?
        let options = spec.mode == "CTR" ? CCModeOptions(kCCModeOptionCTR_BE) : 0
        let status = keyData.withUnsafeBytes { keyPtr in
            withOptionalBytes(ivData) { ivPtr in
                CCCryptorCreateWithMode(
                    CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), mode, alg, padding,
                    ivPtr, keyPtr.baseAddress, keyData.count, nil, 0, 0, options, &cryptor
                )
            }
        }
        guard status == kCCSuccess, let cryptor else { throw CryptoError.failed("创建失败(\(status))") }
        defer { CCCryptorRelease(cryptor) }
        let outLength = CCCryptorGetOutputLength(cryptor, input.count, true)
        var out = Data(count: outLength)
        var moved = 0
        var finalMoved = 0
        let s1 = out.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                CCCryptorUpdate(cryptor, inPtr.baseAddress, input.count, outPtr.baseAddress, outLength, &moved)
            }
        }
        guard s1 == kCCSuccess else { throw CryptoError.failed("处理失败(\(s1))") }
        let s2 = out.withUnsafeMutableBytes { outPtr in
            CCCryptorFinal(cryptor, outPtr.baseAddress! + moved, outLength - moved, &finalMoved)
        }
        guard s2 == kCCSuccess else { throw CryptoError.failed("填充校验失败(\(s2))") }
        out.count = moved + finalMoved
        if !encrypt, spec.padding == "ZEROPADDING" {
            while let last = out.last, last == 0 { out.removeLast() }
        }
        return out
    }

    private static func algorithm(_ spec: CipherSpec, key: Data) throws -> (CCAlgorithm, Data) {
        switch spec.algorithm {
        case "AES":
            // 与 Hutool 一致：只接受 16/24/32 字节，不截断、不补零
            guard [16, 24, 32].contains(key.count) else { throw CryptoError.invalidKey("AES 密钥长度为 \(key.count)") }
            return (CCAlgorithm(kCCAlgorithmAES), key)
        case "DES":
            guard key.count >= 8 else { throw CryptoError.invalidKey("DES 密钥长度为 \(key.count)") }
            return (CCAlgorithm(kCCAlgorithmDES), key.prefix(8))
        case "DESEDE":
            if key.count == 16 { return (CCAlgorithm(kCCAlgorithm3DES), key + key.prefix(8)) }
            guard key.count >= 24 else { throw CryptoError.invalidKey("3DES 密钥长度为 \(key.count)") }
            return (CCAlgorithm(kCCAlgorithm3DES), key.prefix(24))
        default:
            throw CryptoError.unsupported(spec.algorithm)
        }
    }

    private static func gcm(encrypt: Bool, key: Data, iv: Data, data: Data, tagLength: Int, aad: Data) throws -> Data {
        guard [16, 24, 32].contains(key.count) else { throw CryptoError.invalidKey("AES 密钥长度为 \(key.count)") }
        let symmetricKey = SymmetricKey(data: key)
        do {
            let nonce = try AES.GCM.Nonce(data: iv)
            if encrypt {
                let box = try AES.GCM.seal(data, using: symmetricKey, nonce: nonce, authenticating: aad)
                return box.ciphertext + box.tag
            }
            guard data.count >= tagLength else { throw CryptoError.failed("密文过短") }
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: data.dropLast(tagLength), tag: data.suffix(tagLength))
            return try AES.GCM.open(box, using: symmetricKey, authenticating: aad)
        } catch let e as CryptoError {
            throw e
        } catch {
            throw CryptoError.failed("GCM: \(error)")
        }
    }

    private static func withOptionalBytes<R>(_ data: Data?, _ body: (UnsafeRawPointer?) -> R) -> R {
        guard let data else { return body(nil) }
        return data.withUnsafeBytes { body($0.baseAddress) }
    }
}

enum Digests {
    static func digest(_ algorithm: String, _ data: Data) -> Data? {
        switch normalize(algorithm) {
        case "MD5": return Data(Insecure.MD5.hash(data: data))
        case "SHA1": return Data(Insecure.SHA1.hash(data: data))
        case "SHA256": return Data(SHA256.hash(data: data))
        case "SHA384": return Data(SHA384.hash(data: data))
        case "SHA512": return Data(SHA512.hash(data: data))
        case "SHA224":
            var out = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
            data.withUnsafeBytes { _ = CC_SHA224($0.baseAddress, CC_LONG(data.count), &out) }
            return Data(out)
        default: return nil
        }
    }

    static func hmac(_ algorithm: String, key: Data, data: Data) -> Data? {
        let k = SymmetricKey(data: key)
        switch normalize(algorithm.replacingOccurrences(of: "hmac", with: "", options: .caseInsensitive)) {
        case "MD5": return Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: k))
        case "SHA1": return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: k))
        case "SHA256": return Data(HMAC<SHA256>.authenticationCode(for: data, using: k))
        case "SHA384": return Data(HMAC<SHA384>.authenticationCode(for: data, using: k))
        case "SHA512": return Data(HMAC<SHA512>.authenticationCode(for: data, using: k))
        default: return nil
        }
    }

    private static func normalize(_ name: String) -> String {
        name.uppercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
    }
}

/// 与 Android `android.util.Base64` 标志位一致的编解码
enum Base64Codec {
    static let noPadding = 1
    static let noWrap = 2
    static let crlf = 4
    static let urlSafe = 8

    static func encode(_ data: Data, flags: Int = noWrap) -> String {
        var s = data.base64EncodedString()
        if flags & urlSafe != 0 {
            s = s.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        if flags & noPadding != 0 {
            while s.hasSuffix("=") { s.removeLast() }
        }
        if flags & noWrap == 0 {
            let newline = flags & crlf != 0 ? "\r\n" : "\n"
            var wrapped = ""
            var index = s.startIndex
            while index < s.endIndex {
                let end = s.index(index, offsetBy: 76, limitedBy: s.endIndex) ?? s.endIndex
                wrapped += s[index..<end] + newline
                index = end
            }
            s = wrapped
        }
        return s
    }

    /// 宽松解码：忽略空白，同时接受标准与 URL 安全字母表，自动补齐填充
    static func decode(_ text: String) -> Data? {
        var s = text.filter { !$0.isWhitespace }
        s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if let comma = s.firstIndex(of: ","), s.hasPrefix("data:") {
            s = String(s[s.index(after: comma)...])
        }
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}

enum Hex {
    static func encode(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for b in data {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ text: String) -> Data? {
        let chars = Array(text.utf8).filter { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = value(chars[i]), let lo = value(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    static func isHex(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { value($0) != nil }
    }

    private static func value(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }
}
