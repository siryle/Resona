import AVFoundation
import AudioToolbox
import CommonCrypto
import Darwin
import dnssd
import Foundation
import MediaToolbox
import Network
import Security
import os

struct RAOPDeviceInfo: Equatable {
    let id: String
    let macHex: String
    let serviceName: String
    let displayName: String
    let codecs: Set<Int>
    let encryptionTypes: Set<Int>
    let requiresPassword: Bool
    let interfaceIndex: UInt32

    var asAudioOutputDevice: AudioOutputDevice {
        AudioOutputDevice(id: id, name: displayName, kind: .airPlay, isDefault: false)
    }
}

enum RAOPError: LocalizedError {
    case deviceNotFound
    case resolutionFailed(String)
    case connectionFailed(String)
    case passwordRequired
    case protocolError(String)
    case cryptoError(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "未找到该 AirPlay 音箱，请刷新后重试。"
        case .resolutionFailed(let detail):
            return "无法解析音箱地址：\(detail)"
        case .connectionFailed(let detail):
            return "无法连接 AirPlay 音箱：\(detail)"
        case .passwordRequired:
            return "该 AirPlay 音箱需要密码认证，暂不支持直连。"
        case .protocolError(let detail):
            return "AirPlay 握手失败：\(detail)"
        case .cryptoError(let detail):
            return "AirPlay 加密初始化失败：\(detail)"
        }
    }
}

final class RAOPDiscovery {
    var onChange: (() -> Void)?
    private(set) var devices: [RAOPDeviceInfo] = []
    private(set) var hasAirPlay2Targets = false

    private let queue = DispatchQueue(label: "app.resona.raop.discovery")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let localMACs: Set<String>
    private var raopBrowser: NWBrowser?
    private var airPlayBrowser: NWBrowser?
    private var rawRAOPResults: [NWBrowser.Result] = []
    private var rawAirPlayResults: [NWBrowser.Result] = []

    init(localMACs: Set<String> = RAOPDiscovery.localHardwareMACs()) {
        self.localMACs = localMACs
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    func start() {
        queue.async { [weak self] in
            self?.startBrowsersOnQueue()
        }
    }

    func refresh() {
        queue.async { [weak self] in
            self?.stopBrowsersOnQueue()
            self?.rawRAOPResults = []
            self?.rawAirPlayResults = []
            self?.recomputeOnQueue()
            self?.startBrowsersOnQueue()
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopBrowsersOnQueue()
        } else {
            queue.sync { stopBrowsersOnQueue() }
        }
    }

    func device(forID id: String) -> RAOPDeviceInfo? {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return devices.first(where: { $0.id == id })
        }
        return queue.sync { devices.first(where: { $0.id == id }) }
    }

    private func startBrowsersOnQueue() {
        guard raopBrowser == nil, airPlayBrowser == nil else { return }

        let raopParams = NWParameters()
        raopParams.includePeerToPeer = false
        let raop = NWBrowser(for: .bonjourWithTXTRecord(type: "_raop._tcp", domain: "local."), using: raopParams)
        raop.browseResultsChangedHandler = { [weak self] results, _ in
            self?.rawRAOPResults = Array(results)
            self?.recomputeOnQueue()
        }
        raopBrowser = raop
        raop.start(queue: queue)

        let apParams = NWParameters()
        apParams.includePeerToPeer = false
        let ap = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: "local."), using: apParams)
        ap.browseResultsChangedHandler = { [weak self] results, _ in
            self?.rawAirPlayResults = Array(results)
            self?.recomputeOnQueue()
        }
        airPlayBrowser = ap
        ap.start(queue: queue)
    }

    private func stopBrowsersOnQueue() {
        raopBrowser?.cancel()
        raopBrowser = nil
        airPlayBrowser?.cancel()
        airPlayBrowser = nil
    }

    private func recomputeOnQueue() {
        var loopbackAirPlayIDs: Set<String> = []
        var externalAirPlay2 = false

        for result in rawAirPlayResults {
            let isLoopback = result.interfaces.contains(where: { $0.type == .loopback || $0.name == "lo0" })
            var dict: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                dict = record.dictionary
            }
            let normalizedID = Self.normalizeHex(dict["deviceid"] ?? "")
            if isLoopback {
                if !normalizedID.isEmpty { loopbackAirPlayIDs.insert(normalizedID) }
                continue
            }
            if !normalizedID.isEmpty && (localMACs.contains(normalizedID) || loopbackAirPlayIDs.contains(normalizedID)) {
                continue
            }
            externalAirPlay2 = true
        }

        var byID: [String: RAOPDeviceInfo] = [:]
        for result in rawRAOPResults {
            guard case .service(let serviceName, _, _, _) = result.endpoint else { continue }
            let isLoopback = result.interfaces.contains(where: { $0.type == .loopback || $0.name == "lo0" })
            var dict: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                dict = record.dictionary
            }
            let interfaceName = result.interfaces.first(where: { $0.type != .loopback })?.name ?? result.interfaces.first?.name
            let ifIndex = interfaceName.map { if_nametoindex($0) } ?? 0
            guard let info = Self.classifyRAOPService(
                serviceName: serviceName,
                txt: dict,
                isLoopback: isLoopback,
                localAirPlayDeviceIDs: loopbackAirPlayIDs,
                localMACs: localMACs,
                interfaceIndex: ifIndex
            ) else { continue }
            if let existing = byID[info.id] {
                if existing.interfaceIndex == 0 && info.interfaceIndex != 0 {
                    byID[info.id] = info
                }
            } else {
                byID[info.id] = info
            }
        }

        let sorted = byID.values.sorted {
            let cmp = $0.displayName.localizedStandardCompare($1.displayName)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return $0.macHex < $1.macHex
        }

        let changed = sorted != devices || externalAirPlay2 != hasAirPlay2Targets
        devices = sorted
        hasAirPlay2Targets = externalAirPlay2
        if changed {
            DispatchQueue.main.async { [weak self] in
                self?.onChange?()
            }
        }
    }

    static func classifyRAOPService(
        serviceName: String,
        txt: [String: String],
        isLoopback: Bool,
        localAirPlayDeviceIDs: Set<String>,
        localMACs: Set<String>,
        interfaceIndex: UInt32 = 0
    ) -> RAOPDeviceInfo? {
        guard !isLoopback, let atIndex = serviceName.firstIndex(of: "@") else { return nil }
        let rawMac = String(serviceName[..<atIndex])
        let displayName = String(serviceName[serviceName.index(after: atIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let macHex = normalizeHex(rawMac)
        guard !macHex.isEmpty, !displayName.isEmpty else { return nil }
        guard !localAirPlayDeviceIDs.contains(macHex), !localMACs.contains(macHex) else { return nil }

        let et = parseIntSet(txt["et"])
        let cn = parseIntSet(txt["cn"])
        // Exclude pure HAP AirPlay 2 endpoints that omit legacy RSA RAOP encryption.
        if txt["pk"] != nil && !et.contains(1) { return nil }
        guard et.isEmpty || et.contains(0) || et.contains(1) else { return nil }
        guard cn.isEmpty || cn.contains(0) || cn.contains(1) else { return nil }

        let requiresPassword = (txt["pw"]?.lowercased() == "true") || txt["pw"] == "1"
        return RAOPDeviceInfo(
            id: "raop:\(macHex)",
            macHex: macHex,
            serviceName: serviceName,
            displayName: displayName,
            codecs: cn,
            encryptionTypes: et,
            requiresPassword: requiresPassword,
            interfaceIndex: interfaceIndex
        )
    }

    static func normalizeHex(_ value: String) -> String {
        value.uppercased().filter { $0.isHexDigit }
    }

    private static func parseIntSet(_ raw: String?) -> Set<Int> {
        guard let raw else { return [] }
        return Set(raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    static func localHardwareMACs() -> Set<String> {
        var result: Set<String> = []
        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPtr) == 0, let head = ifaddrsPtr else { return result }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr, Int32(addr.pointee.sa_family) == AF_LINK else { continue }
            let sdl = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
            let addrLen = Int(sdl.sdl_alen)
            guard addrLen == 6 else { continue }
            let nameLen = Int(sdl.sdl_nlen)
            let bytes = addr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<sockaddr_dl>.size) { raw in
                // sdl_data starts at offset 8 in Darwin sockaddr_dl.
                let offset = 8 + nameLen
                return (0..<addrLen).map { String(format: "%02X", raw[offset + $0]) }.joined()
            }
            if !bytes.isEmpty { result.insert(bytes) }
        }
        return result
    }
}

enum RAOPResolver {
    private final class ResolveState {
        var finished = false
        var errorCode: DNSServiceErrorType = 0
        var hostTarget = ""
        var port: UInt16 = 0
        var resolvedInterface: UInt32 = 0
    }

    private final class AddrState {
        var finished = false
        var errorCode: DNSServiceErrorType = 0
        var ipv4 = ""
    }

    static func resolve(serviceName: String, interfaceIndex: UInt32, timeout: TimeInterval = 3.0) async throws -> (host: String, port: UInt16) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try resolveSync(serviceName: serviceName, interfaceIndex: interfaceIndex, timeout: timeout)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func resolveSync(serviceName: String, interfaceIndex: UInt32, timeout: TimeInterval) throws -> (host: String, port: UInt16) {
        let resolveState = ResolveState()
        var resolveRef: DNSServiceRef?
        let context = Unmanaged.passRetained(resolveState).toOpaque()
        defer { Unmanaged<ResolveState>.fromOpaque(context).release() }

        let err = DNSServiceResolve(
            &resolveRef,
            0,
            interfaceIndex,
            serviceName,
            "_raop._tcp.",
            "local.",
            { _, _, ifIndex, errorCode, _, hosttarget, portBE, _, _, ctx in
                guard let ctx else { return }
                let st = Unmanaged<ResolveState>.fromOpaque(ctx).takeUnretainedValue()
                st.errorCode = errorCode
                st.resolvedInterface = ifIndex
                st.port = UInt16(bigEndian: portBE)
                if let hosttarget {
                    st.hostTarget = String(cString: hosttarget)
                }
                st.finished = true
            },
            context
        )
        guard err == kDNSServiceErr_NoError, let resolveRef else {
            throw RAOPError.resolutionFailed("DNSServiceResolve \(err)")
        }
        defer { DNSServiceRefDeallocate(resolveRef) }

        let halfTimeout = max(0.5, timeout * 0.5)
        try pumpService(resolveRef, timeout: halfTimeout) { resolveState.finished }
        guard resolveState.errorCode == kDNSServiceErr_NoError, !resolveState.hostTarget.isEmpty, resolveState.port > 0 else {
            throw RAOPError.resolutionFailed("resolve status \(resolveState.errorCode)")
        }

        let addrState = AddrState()
        var addrRef: DNSServiceRef?
        let addrContext = Unmanaged.passRetained(addrState).toOpaque()
        defer { Unmanaged<AddrState>.fromOpaque(addrContext).release() }

        let aErr = DNSServiceGetAddrInfo(
            &addrRef,
            0,
            interfaceIndex != 0 ? interfaceIndex : resolveState.resolvedInterface,
            DNSServiceProtocol(kDNSServiceProtocol_IPv4),
            resolveState.hostTarget,
            { _, _, _, errorCode, _, address, _, ctx in
                guard let ctx else { return }
                let st = Unmanaged<AddrState>.fromOpaque(ctx).takeUnretainedValue()
                st.errorCode = errorCode
                if errorCode == kDNSServiceErr_NoError, let address, Int32(address.pointee.sa_family) == AF_INET {
                    var inAddr = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        st.ipv4 = String(cString: buf)
                    }
                }
                if errorCode != kDNSServiceErr_NoError || !st.ipv4.isEmpty {
                    st.finished = true
                }
            },
            addrContext
        )
        guard aErr == kDNSServiceErr_NoError, let addrRef else {
            throw RAOPError.resolutionFailed("DNSServiceGetAddrInfo \(aErr)")
        }
        defer { DNSServiceRefDeallocate(addrRef) }

        try pumpService(addrRef, timeout: halfTimeout) { addrState.finished }
        guard addrState.errorCode == kDNSServiceErr_NoError, !addrState.ipv4.isEmpty else {
            throw RAOPError.resolutionFailed("IPv4 lookup status \(addrState.errorCode)")
        }
        return (addrState.ipv4, resolveState.port)
    }

    private static func pumpService(_ ref: DNSServiceRef, timeout: TimeInterval, isDone: () -> Bool) throws {
        let fd = DNSServiceRefSockFD(ref)
        guard fd >= 0 else { throw RAOPError.resolutionFailed("invalid mDNS fd") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !isDone() {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { throw RAOPError.resolutionFailed("mDNS 超时") }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waitMs = max(10, Int32(min(remaining, 0.25) * 1000))
            let rc = poll(&pfd, 1, waitMs)
            if rc < 0 {
                if errno == EINTR { continue }
                throw RAOPError.resolutionFailed("poll errno \(errno)")
            }
            if rc > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                let pErr = DNSServiceProcessResult(ref)
                if pErr != kDNSServiceErr_NoError {
                    throw RAOPError.resolutionFailed("DNSServiceProcessResult \(pErr)")
                }
            }
        }
    }
}

final class RAOPCrypto {
    // Standard 2048-bit AirPort Express RSA public key used for RAOP AES session key wrapping.
    private static let appleRSAModulusBase64 =
        "59dE8qLieItsH1WgjrcFRKj6eUWqi+bGLOX1HL3U3GhC/j0Qg90u3sG/1CUtwC" +
        "5vOYvfDmFI6oSFXi5ELabWJmT2dKHzBJKa3k9ok+8t9ucRqMd6DZHJ2YCCLlDR" +
        "KSKv6kDqnw4UwPdpOMXziC/AMj3Z/lUVX1G7WSHCAWKf1zNS1eLvqr+boEjXuB" +
        "OitnZ/bDzPHrTOZz0Dew0uowxf/+sG+NCK3eQJVxqcaJ/vEHKIVd2M+5qL71yJ" +
        "Q+87X6oV3eaYvt3zWZYD6z5vYTcrtij2VZ9Zmni/UAaHqn9JdsBWLUEpVviYnh" +
        "imNVvYFZeCXg/IdTQ+x4IRdiXNv5hEew=="

    let aesKey: Data
    let aesIV: Data
    private let publicKey: SecKey

    init() throws {
        var key = [UInt8](repeating: 0, count: 16)
        var iv = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, key.count, &key) == errSecSuccess,
              SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv) == errSecSuccess else {
            throw RAOPError.cryptoError("无法生成随机密钥")
        }
        self.aesKey = Data(key)
        self.aesIV = Data(iv)
        self.publicKey = try Self.makePublicKey()
    }

    init(aesKey: Data, aesIV: Data) throws {
        guard aesKey.count == 16, aesIV.count == 16 else {
            throw RAOPError.cryptoError("AES 密钥长度无效")
        }
        self.aesKey = aesKey
        self.aesIV = aesIV
        self.publicKey = try Self.makePublicKey()
    }

    private static func makePublicKey() throws -> SecKey {
        guard let modulus = Data(base64Encoded: appleRSAModulusBase64) else {
            throw RAOPError.cryptoError("RSA 公钥解码失败")
        }
        let exponent = Data([0x01, 0x00, 0x01])
        let der = derSequence(derInteger(modulus) + derInteger(exponent))
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulus.count * 8
        ]
        var cfErr: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &cfErr) else {
            throw RAOPError.cryptoError(cfErr?.takeRetainedValue().localizedDescription ?? "SecKey 初始化失败")
        }
        return key
    }

    private static func derLength(_ n: Int) -> Data {
        if n < 128 { return Data([UInt8(n)]) }
        if n < 256 { return Data([0x81, UInt8(n)]) }
        return Data([0x82, UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
    }

    private static func derInteger(_ bytes: Data) -> Data {
        var b = bytes
        if let first = b.first, (first & 0x80) != 0 {
            b.insert(0x00, at: 0)
        }
        return Data([0x02]) + derLength(b.count) + b
    }

    private static func derSequence(_ content: Data) -> Data {
        Data([0x30]) + derLength(content.count) + content
    }

    func encryptedAESKeyBase64() throws -> String {
        var cfErr: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            publicKey, .rsaEncryptionOAEPSHA1, aesKey as CFData, &cfErr
        ) as Data? else {
            throw RAOPError.cryptoError(cfErr?.takeRetainedValue().localizedDescription ?? "RSA 加密失败")
        }
        return encrypted.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    func aesIVBase64() -> String {
        aesIV.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    func encryptAudioPayload(_ plain: Data) -> Data {
        let blockCount = plain.count / kCCBlockSizeAES128
        let alignedBytes = blockCount * kCCBlockSizeAES128
        guard alignedBytes > 0 else { return plain }

        var output = Data(count: plain.count)
        var outLen = 0
        let status = output.withUnsafeMutableBytes { outBuf in
            plain.withUnsafeBytes { inBuf in
                aesKey.withUnsafeBytes { keyBuf in
                    aesIV.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(0),
                            keyBuf.baseAddress, kCCKeySizeAES128,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, alignedBytes,
                            outBuf.baseAddress, alignedBytes,
                            &outLen
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, outLen == alignedBytes else { return plain }
        let remainder = plain.count - alignedBytes
        if remainder > 0 {
            output.replaceSubrange(alignedBytes..<plain.count, with: plain[alignedBytes..<plain.count])
        }
        return output
    }
}

final class RAOPAudioEncoder {
    enum Codec {
        case alac
        case pcmL16
    }

    static let framesPerPacket = 352
    static let sampleRate: Double = 44100
    static let channels: UInt32 = 2

    let codec: Codec
    let magicCookie: Data?
    private let pcmFormat: AVAudioFormat
    private let alacFormat: AVAudioFormat?
    private let converter: AVAudioConverter?
    private let inputBuffer: AVAudioPCMBuffer
    private let compressedBuffer: AVAudioCompressedBuffer?

    init(supportedCodecs: Set<Int>) {
        let pcmFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: true
        )!
        self.pcmFormat = pcmFmt
        self.inputBuffer = AVAudioPCMBuffer(pcmFormat: pcmFmt, frameCapacity: AVAudioFrameCount(Self.framesPerPacket))!

        if supportedCodecs.isEmpty || supportedCodecs.contains(1) {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Self.sampleRate,
                mFormatID: kAudioFormatAppleLossless,
                mFormatFlags: UInt32(kAppleLosslessFormatFlag_16BitSourceData),
                mBytesPerPacket: 0,
                mFramesPerPacket: UInt32(Self.framesPerPacket),
                mBytesPerFrame: 0,
                mChannelsPerFrame: Self.channels,
                mBitsPerChannel: 0,
                mReserved: 0
            )
            if let outFmt = AVAudioFormat(streamDescription: &asbd),
               let conv = AVAudioConverter(from: pcmFmt, to: outFmt) {
                self.codec = .alac
                self.alacFormat = outFmt
                self.converter = conv
                self.magicCookie = conv.magicCookie
                self.compressedBuffer = AVAudioCompressedBuffer(format: outFmt, packetCapacity: 1, maximumPacketSize: 4096)
                return
            }
        }

        self.codec = .pcmL16
        self.alacFormat = nil
        self.converter = nil
        self.magicCookie = nil
        self.compressedBuffer = nil
    }

    func encode(interleavedStereoInt16 samples: [Int16]) -> Data {
        precondition(samples.count == Self.framesPerPacket * 2)
        switch codec {
        case .alac:
            if let converter, let compressedBuffer {
                inputBuffer.frameLength = AVAudioFrameCount(Self.framesPerPacket)
                let dst = inputBuffer.int16ChannelData![0]
                samples.withUnsafeBufferPointer { src in
                    _ = memcpy(dst, src.baseAddress!, samples.count * MemoryLayout<Int16>.size)
                }
                compressedBuffer.packetCount = 0
                compressedBuffer.byteLength = 0
                var fed = false
                var error: NSError?
                let status = converter.convert(to: compressedBuffer, error: &error) { _, outStatus in
                    if fed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    outStatus.pointee = .haveData
                    return self.inputBuffer
                }
                if (status == .haveData || status == .inputRanDry) && compressedBuffer.byteLength > 0 && error == nil {
                    return Data(bytes: compressedBuffer.data, count: Int(compressedBuffer.byteLength))
                }
            }
            return encodeL16(samples)
        case .pcmL16:
            return encodeL16(samples)
        }
    }

    private func encodeL16(_ samples: [Int16]) -> Data {
        var data = Data(count: samples.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0..<samples.count {
                out[i] = samples[i].bigEndian
            }
        }
        return data
    }
}

final class RAOPPCMBuffer {
    private var lock = os_unfair_lock_s()
    private let capacityFrames: Int
    private var storage: [Int16]
    private var readIndex = 0
    private var writeIndex = 0
    private var frameCount = 0

    init(capacityFrames: Int = 44100 * 4) {
        self.capacityFrames = max(352 * 8, capacityFrames)
        self.storage = [Int16](repeating: 0, count: self.capacityFrames * 2)
    }

    var availableFrames: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return frameCount
    }

    func append(interleavedStereoInt16 samples: UnsafePointer<Int16>, frameCount incoming: Int) {
        guard incoming > 0 else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        var srcPtr = samples
        var count = incoming
        if count >= capacityFrames {
            srcPtr = srcPtr.advanced(by: (count - capacityFrames) * 2)
            count = capacityFrames
            readIndex = 0
            writeIndex = 0
            frameCount = 0
        } else if frameCount + count > capacityFrames {
            let drop = (frameCount + count) - capacityFrames
            readIndex = (readIndex + drop) % capacityFrames
            frameCount -= drop
        }

        let firstFrames = min(count, capacityFrames - writeIndex)
        storage.withUnsafeMutableBufferPointer { dst in
            let base = dst.baseAddress!
            _ = memcpy(base.advanced(by: writeIndex * 2), srcPtr, firstFrames * 2 * MemoryLayout<Int16>.size)
            let remaining = count - firstFrames
            if remaining > 0 {
                _ = memcpy(base, srcPtr.advanced(by: firstFrames * 2), remaining * 2 * MemoryLayout<Int16>.size)
            }
        }
        writeIndex = (writeIndex + count) % capacityFrames
        frameCount += count
    }

    func popFrames(_ count: Int) -> [Int16]? {
        guard count > 0 else { return [] }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard frameCount >= count else { return nil }

        var out = [Int16](repeating: 0, count: count * 2)
        let firstFrames = min(count, capacityFrames - readIndex)
        out.withUnsafeMutableBufferPointer { dst in
            storage.withUnsafeBufferPointer { src in
                let dstBase = dst.baseAddress!
                let srcBase = src.baseAddress!
                _ = memcpy(dstBase, srcBase.advanced(by: readIndex * 2), firstFrames * 2 * MemoryLayout<Int16>.size)
                let remaining = count - firstFrames
                if remaining > 0 {
                    _ = memcpy(dstBase.advanced(by: firstFrames * 2), srcBase, remaining * 2 * MemoryLayout<Int16>.size)
                }
            }
        }
        readIndex = (readIndex + count) % capacityFrames
        frameCount -= count
        return out
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        readIndex = 0
        writeIndex = 0
        frameCount = 0
        os_unfair_lock_unlock(&lock)
    }
}

final class RAOPAudioTap {
    private final class Context {
        let buffer: RAOPPCMBuffer
        let targetFormat: AVAudioFormat
        var sourceFormat: AVAudioFormat?
        var converter: AVAudioConverter?
        var inputBuffer: AVAudioPCMBuffer?
        var outputBuffer: AVAudioPCMBuffer?
        private var inputBytesPerFrame = 4

        init(buffer: RAOPPCMBuffer) {
            self.buffer = buffer
            self.targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: RAOPAudioEncoder.sampleRate,
                channels: RAOPAudioEncoder.channels,
                interleaved: true
            )!
        }

        func configure(maxFrames: CMItemCount, processingFormat: AudioStreamBasicDescription) {
            var asbd = processingFormat
            guard let inFmt = AVAudioFormat(streamDescription: &asbd),
                  let conv = AVAudioConverter(from: inFmt, to: targetFormat) else { return }
            let inCap = AVAudioFrameCount(max(Int(maxFrames), 4096))
            let ratio = targetFormat.sampleRate / max(1, inFmt.sampleRate)
            let outCap = AVAudioFrameCount(max(Int(ceil(Double(inCap) * ratio)) + 256, 4096))
            sourceFormat = inFmt
            converter = conv
            inputBytesPerFrame = max(1, Int(inFmt.streamDescription.pointee.mBytesPerFrame))
            inputBuffer = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inCap)
            outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap)
        }

        func handleAudio(frames: AVAudioFrameCount, bufferList: UnsafePointer<AudioBufferList>) {
            guard frames > 0, let converter, let inputBuffer, let outputBuffer else { return }
            let inCount = min(frames, inputBuffer.frameCapacity)
            inputBuffer.frameLength = inCount
            let srcList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            let dstList = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)
            let count = min(srcList.count, dstList.count)
            for i in 0..<count {
                let copyBytes = min(Int(inCount) * inputBytesPerFrame, Int(srcList[i].mDataByteSize))
                if let srcData = srcList[i].mData, let dstData = dstList[i].mData, copyBytes > 0 {
                    _ = memcpy(dstData, srcData, copyBytes)
                }
                dstList[i].mDataByteSize = UInt32(copyBytes)
            }

            outputBuffer.frameLength = outputBuffer.frameCapacity
            var fed = false
            var err: NSError?
            let st = converter.convert(to: outputBuffer, error: &err) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            if (st == .haveData || st == .inputRanDry), err == nil,
               outputBuffer.frameLength > 0, let int16Ptr = outputBuffer.int16ChannelData?[0] {
                buffer.append(interleavedStereoInt16: int16Ptr, frameCount: Int(outputBuffer.frameLength))
            }
        }
    }

    @MainActor
    func attach(to item: AVPlayerItem, buffer: RAOPPCMBuffer) async {
        guard let tracks = try? await item.asset.loadTracks(withMediaType: .audio),
              let track = tracks.first else { return }
        let context = Context(buffer: buffer)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, maxFrames, processingFormat in
                let ctx = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                ctx.configure(maxFrames: maxFrames, processingFormat: processingFormat.pointee)
            },
            unprepare: { _ in },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let ctx = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let st = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                if st == noErr {
                    ctx.handleAudio(frames: AVAudioFrameCount(numberFramesOut.pointee), bufferList: bufferListInOut)
                }
                for buf in UnsafeMutableAudioBufferListPointer(bufferListInOut) {
                    if let mData = buf.mData, buf.mDataByteSize > 0 {
                        memset(mData, 0, Int(buf.mDataByteSize))
                    }
                }
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        guard status == noErr, let tap else { return }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }

    @MainActor
    func detach(from item: AVPlayerItem) {
        item.audioMix = nil
    }
}

final class RAOPSession: @unchecked Sendable {
    var onDisconnect: ((String?) -> Void)?

    private let host: String
    private let port: UInt16
    private let deviceName: String
    private let encoder: RAOPAudioEncoder
    private let useEncryption: Bool
    private let crypto: RAOPCrypto?
    private let buffer: RAOPPCMBuffer
    private let queue = DispatchQueue(label: "app.resona.raop.session", qos: .userInteractive)

    private var rtspFD: Int32 = -1
    private var audioFD: Int32 = -1
    private var controlFD: Int32 = -1
    private var timingFD: Int32 = -1
    private var remoteAddr = sockaddr_in()
    private var remoteControlAddr = sockaddr_in()
    private var remoteTimingAddr = sockaddr_in()
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var localIP = "0.0.0.0"
    private var localControlPort: UInt16 = 0
    private var localTimingPort: UInt16 = 0

    private let sessionID = String(format: "%010u", UInt32.random(in: 100000000...UInt32.max))
    private let clientInstance = String(format: "%016llX", UInt64.random(in: 1...UInt64.max))
    private let activeRemote = String(UInt32.random(in: 100000000...UInt32.max))
    private let ssrc = UInt32.random(in: 1...UInt32.max)
    private var rtspSession = ""
    private var cseq = 0
    private var seq = UInt16.random(in: 1...50000)
    private var rtpTime = UInt32.random(in: 100000...0x7FFF_FFFF)
    private var latencyFrames: UInt32 = 88200

    private var packetRing = [Data?](repeating: nil, count: 256)
    private var packetSeqs = [UInt16](repeating: 0, count: 256)

    private var timer: DispatchSourceTimer?
    private var controlSource: DispatchSourceRead?
    private var timingSource: DispatchSourceRead?
    private var pendingVolumeTask: DispatchWorkItem?
    private var streamActive = false
    private var streamStartTime: TimeInterval = 0
    private var streamFramesSent = 0
    private var nextPacketMarker = true
    private var packetsSinceSync = 0
    private var lastKeepalive: TimeInterval = 0
    private var closed = false
    private var notifyDisconnectOnClose = false

    init(
        host: String,
        port: UInt16,
        deviceName: String,
        codecs: Set<Int>,
        encryptionTypes: Set<Int>,
        buffer: RAOPPCMBuffer
    ) throws {
        self.host = host
        self.port = port
        self.deviceName = deviceName
        self.encoder = RAOPAudioEncoder(supportedCodecs: codecs)
        self.useEncryption = encryptionTypes.isEmpty || encryptionTypes.contains(1)
        self.crypto = self.useEncryption ? try RAOPCrypto() : nil
        self.buffer = buffer
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        disconnectSync(sendTeardown: false, notify: false, reason: nil)
    }

    static func airPlayVolumeDB(for linear: Float) -> Double {
        if !linear.isFinite || linear <= 0.001 {
            return -144.0
        }
        let clamped = Double(min(max(linear, 0), 1))
        return -30.0 * (1.0 - clamped)
    }

    func connect(initialVolume: Float) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: RAOPError.connectionFailed("会话已释放"))
                    return
                }
                do {
                    try self.connectOnQueue(initialVolume: initialVolume)
                    continuation.resume()
                } catch {
                    self.disconnectSync(sendTeardown: false, notify: false, reason: nil)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func setVolume(_ linear: Float) {
        queue.async { [weak self] in
            guard let self, !self.closed, self.rtspFD >= 0 else { return }
            self.pendingVolumeTask?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.closed, self.rtspFD >= 0 else { return }
                do {
                    try self.sendVolumeOnQueue(linear)
                } catch {
                    self.disconnectSync(sendTeardown: false, notify: true, reason: error.localizedDescription)
                }
            }
            self.pendingVolumeTask = item
            self.queue.asyncAfter(deadline: .now() + .milliseconds(40), execute: item)
        }
    }

    func flush() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.buffer.clear()
            self.streamActive = false
            self.streamFramesSent = 0
            self.nextPacketMarker = true
            self.packetsSinceSync = 0
            guard self.rtspFD >= 0 else { return }
            do {
                let extra = ["RTP-Info": "seq=\(self.seq);rtptime=\(self.rtpTime)"]
                _ = try self.rtspRequest("FLUSH", headers: extra)
            } catch {
                self.disconnectSync(sendTeardown: false, notify: true, reason: error.localizedDescription)
            }
        }
    }

    func disconnect() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            disconnectSync(sendTeardown: true, notify: false, reason: nil)
        } else {
            queue.sync {
                disconnectSync(sendTeardown: true, notify: false, reason: nil)
            }
        }
    }

    private func connectOnQueue(initialVolume: Float) throws {
        closed = false
        let (tcpFD, peerAddr, localIP) = try openTCPSocket(host: host, port: port, timeout: 5.0)
        self.rtspFD = tcpFD
        self.localIP = localIP
        self.remoteAddr = peerAddr
        self.remoteControlAddr = peerAddr
        self.remoteTimingAddr = peerAddr

        let (aFD, _) = try openUDPSocket()
        let (cFD, cPort) = try openUDPSocket()
        let (tFD, tPort) = try openUDPSocket()
        self.audioFD = aFD
        self.controlFD = cFD
        self.timingFD = tFD
        self.localControlPort = cPort
        self.localTimingPort = tPort

        installUDPListeners()

        let optResp = try rtspRequest("OPTIONS")
        if optResp.status == 401 { throw RAOPError.passwordRequired }
        guard optResp.status == 200 else {
            throw RAOPError.protocolError("OPTIONS \(optResp.status)")
        }

        let sdp = try buildSDP(localIP: localIP)
        let annResp = try rtspRequest(
            "ANNOUNCE",
            headers: ["Content-Type": "application/sdp"],
            body: Data(sdp.utf8)
        )
        if annResp.status == 401 { throw RAOPError.passwordRequired }
        guard annResp.status == 200 else {
            throw RAOPError.protocolError("ANNOUNCE \(annResp.status)")
        }

        let transport = "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=\(localControlPort);timing_port=\(localTimingPort)"
        let setupResp = try rtspRequest("SETUP", headers: ["Transport": transport])
        guard setupResp.status == 200 else {
            throw RAOPError.protocolError("SETUP \(setupResp.status)")
        }
        if let sess = setupResp.headers["session"]?.split(separator: ";").first {
            rtspSession = String(sess).trimmingCharacters(in: .whitespaces)
        }
        let trResp = setupResp.headers["transport"] ?? ""
        let serverPort = Self.extractPort("server_port", from: trResp) ?? port
        let rCtrlPort = Self.extractPort("control_port", from: trResp) ?? serverPort
        let rTimPort = Self.extractPort("timing_port", from: trResp) ?? serverPort
        remoteAddr.sin_port = serverPort.bigEndian
        remoteControlAddr.sin_port = rCtrlPort.bigEndian
        remoteTimingAddr.sin_port = rTimPort.bigEndian

        let recResp = try rtspRequest("RECORD", headers: [
            "Range": "npt=0-",
            "RTP-Info": "seq=\(seq);rtptime=\(rtpTime)"
        ])
        guard recResp.status == 200 else {
            throw RAOPError.protocolError("RECORD \(recResp.status)")
        }
        if let latStr = recResp.headers["audio-latency"], let lat = UInt32(latStr.trimmingCharacters(in: .whitespaces)) {
            latencyFrames = min(max(lat, 11025), 176400)
        }

        try sendVolumeOnQueue(initialVolume)

        lastKeepalive = ProcessInfo.processInfo.systemUptime
        notifyDisconnectOnClose = true
        startPacer()
    }

    private func sendVolumeOnQueue(_ linear: Float) throws {
        let db = Self.airPlayVolumeDB(for: linear)
        let body = Data(String(format: "volume: %.6f\r\n", db).utf8)
        let resp = try rtspRequest("SET_PARAMETER", headers: ["Content-Type": "text/parameters"], body: body)
        guard resp.status == 200 else {
            throw RAOPError.protocolError("SET_PARAMETER \(resp.status)")
        }
    }

    private func buildSDP(localIP: String) throws -> String {
        var lines = [
            "v=0",
            "o=iTunes \(sessionID) 0 IN IP4 \(localIP)",
            "s=iTunes",
            "c=IN IP4 \(host)",
            "t=0 0",
            "m=audio 0 RTP/AVP 96"
        ]
        switch encoder.codec {
        case .alac:
            lines.append("a=rtpmap:96 AppleLossless")
            lines.append("a=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100")
        case .pcmL16:
            lines.append("a=rtpmap:96 L16/44100/2")
        }
        if let crypto {
            lines.append("a=rsaaeskey:\(try crypto.encryptedAESKeyBase64())")
            lines.append("a=aesiv:\(crypto.aesIVBase64())")
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func extractPort(_ key: String, from header: String) -> UInt16? {
        for part in header.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix(key.lowercased() + "=") {
                let value = trimmed.dropFirst(key.count + 1).split(separator: "-").first ?? ""
                if let port = UInt16(value), port > 0 { return port }
            }
        }
        return nil
    }

    private struct RTSPResponse {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private func rtspRequest(_ method: String, headers: [String: String] = [:], body: Data? = nil) throws -> RTSPResponse {
        guard rtspFD >= 0 else { throw RAOPError.connectionFailed("连接未建立") }
        cseq += 1
        let requestURI = method == "OPTIONS" ? "*" : "rtsp://\(localIP)/\(sessionID)"
        var lines = [
            "\(method) \(requestURI) RTSP/1.0",
            "CSeq: \(cseq)",
            "User-Agent: iTunes/10.6 (Macintosh; Intel Mac OS X 10.7.3) AppleWebKit/535.18.5",
            "Client-Instance: \(clientInstance)",
            "DACP-ID: \(clientInstance)",
            "Active-Remote: \(activeRemote)"
        ]
        if !rtspSession.isEmpty {
            lines.append("Session: \(rtspSession)")
        }
        for (k, v) in headers {
            lines.append("\(k): \(v)")
        }
        if let body {
            lines.append("Content-Length: \(body.count)")
        }
        var packet = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body { packet.append(body) }
        try writeAll(rtspFD, data: packet)
        return try readRTSPResponse(rtspFD)
    }

    private func writeAll(_ fd: Int32, data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while sent < data.count {
                let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 {
                    if errno == EINTR { continue }
                    throw RAOPError.connectionFailed("写入失败 (\(errno))")
                }
                sent += n
            }
        }
    }

    private func readRTSPResponse(_ fd: Int32) throws -> RTSPResponse {
        var accumulated = Data()
        var chunk = [UInt8](repeating: 0, count: 2048)
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        var headerRange: Range<Data.Index>?

        while headerRange == nil {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n < 0 {
                if errno == EINTR { continue }
                throw RAOPError.connectionFailed("读取响应超时或失败 (\(errno))")
            }
            if n == 0 {
                throw RAOPError.connectionFailed("音箱关闭了连接")
            }
            accumulated.append(contentsOf: chunk[0..<n])
            if let range = accumulated.range(of: separator) {
                headerRange = range
                break
            }
            if accumulated.count > 65536 {
                throw RAOPError.protocolError("RTSP 响应头过长")
            }
        }

        let range = headerRange!
        let headerText = String(decoding: accumulated[..<range.lowerBound], as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw RAOPError.protocolError("无效 RTSP 状态行")
        }
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let code = Int(statusParts[1]) else {
            throw RAOPError.protocolError("无法解析状态码: \(statusLine)")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }

        var body = Data(accumulated[range.upperBound...])
        if let lenStr = headers["content-length"], let contentLength = Int(lenStr), contentLength > body.count {
            while body.count < contentLength {
                let n = Darwin.recv(fd, &chunk, min(chunk.count, contentLength - body.count), 0)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    break
                }
                body.append(contentsOf: chunk[0..<n])
            }
        }
        return RTSPResponse(status: code, headers: headers, body: body)
    }

    private func installUDPListeners() {
        let cSrc = DispatchSource.makeReadSource(fileDescriptor: controlFD, queue: queue)
        cSrc.setEventHandler { [weak self] in
            self?.handleControlPacket()
        }
        cSrc.resume()
        controlSource = cSrc

        let tSrc = DispatchSource.makeReadSource(fileDescriptor: timingFD, queue: queue)
        tSrc.setEventHandler { [weak self] in
            self?.handleTimingPacket()
        }
        tSrc.resume()
        timingSource = tSrc
    }

    private func startPacer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            self?.pumpAudio()
        }
        t.resume()
        timer = t
    }

    private func pumpAudio() {
        guard !closed, audioFD >= 0, controlFD >= 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime

        if now - lastKeepalive >= 20 {
            lastKeepalive = now
            do {
                _ = try rtspRequest("OPTIONS")
            } catch {
                disconnectSync(sendTeardown: false, notify: true, reason: error.localizedDescription)
                return
            }
        }

        guard buffer.availableFrames >= RAOPAudioEncoder.framesPerPacket else {
            return
        }

        if !streamActive {
            streamActive = true
            streamStartTime = now
            streamFramesSent = 0
            nextPacketMarker = true
            packetsSinceSync = 0
            sendSyncPacket(isFirst: true)
        }

        var burst = 0
        let allowedFrames = (now - streamStartTime) * RAOPAudioEncoder.sampleRate + Double(RAOPAudioEncoder.framesPerPacket * 4)
        while burst < 4,
              buffer.availableFrames >= RAOPAudioEncoder.framesPerPacket,
              Double(streamFramesSent) <= allowedFrames,
              let frames = buffer.popFrames(RAOPAudioEncoder.framesPerPacket) {
            sendAudioPacket(frames: frames)
            streamFramesSent += RAOPAudioEncoder.framesPerPacket
            burst += 1
            packetsSinceSync += 1
            if packetsSinceSync >= 125 {
                packetsSinceSync = 0
                sendSyncPacket(isFirst: false)
            }
        }
    }

    private func sendAudioPacket(frames: [Int16]) {
        let encoded = encoder.encode(interleavedStereoInt16: frames)
        let payload = crypto?.encryptAudioPayload(encoded) ?? encoded

        var rtp = Data(capacity: 12 + payload.count)
        let pt: UInt8 = nextPacketMarker ? 0xE0 : 0x60
        nextPacketMarker = false
        rtp.append(0x80)
        rtp.append(pt)
        appendBE16(&rtp, seq)
        appendBE32(&rtp, rtpTime)
        appendBE32(&rtp, ssrc)
        rtp.append(payload)

        let slot = Int(seq) % packetRing.count
        packetRing[slot] = rtp
        packetSeqs[slot] = seq

        sendUDP(fd: audioFD, data: rtp, to: &remoteAddr)
        seq &+= 1
        rtpTime &+= UInt32(RAOPAudioEncoder.framesPerPacket)
    }

    private func sendSyncPacket(isFirst: Bool) {
        var sync = Data(capacity: 20)
        sync.append(isFirst ? 0x90 : 0x80)
        sync.append(0xD4)
        appendBE16(&sync, 0x0007)
        let curTime = rtpTime &- latencyFrames
        appendBE32(&sync, curTime)
        let (sec, frac) = Self.currentNTP()
        appendBE32(&sync, sec)
        appendBE32(&sync, frac)
        appendBE32(&sync, rtpTime)
        sendUDP(fd: controlFD, data: sync, to: &remoteControlAddr)
    }

    private func handleControlPacket() {
        var buf = [UInt8](repeating: 0, count: 256)
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(controlFD, &buf, buf.count, 0, sa, &addrLen)
            }
        }
        guard n >= 8, (buf[1] & 0x7F) == 0x55 else { return }
        let firstSeq = (UInt16(buf[4]) << 8) | UInt16(buf[5])
        let count = min(Int((UInt16(buf[6]) << 8) | UInt16(buf[7])), packetRing.count)
        guard count > 0 else { return }
        for offset in 0..<count {
            let targetSeq = firstSeq &+ UInt16(offset)
            let slot = Int(targetSeq) % packetRing.count
            guard packetSeqs[slot] == targetSeq, let cached = packetRing[slot] else { continue }
            var resend = Data([0x80, 0xD6, 0x00, 0x01])
            resend.append(cached)
            sendUDP(fd: controlFD, data: resend, to: &remoteControlAddr)
        }
    }

    private func handleTimingPacket() {
        var buf = [UInt8](repeating: 0, count: 64)
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(timingFD, &buf, buf.count, 0, sa, &addrLen)
            }
        }
        guard n >= 32, (buf[1] & 0x7F) == 0x52 else { return }
        let (sec, frac) = Self.currentNTP()
        var reply = Data([0x80, 0xD3, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00])
        reply.append(contentsOf: buf[24..<32])
        appendBE32(&reply, sec)
        appendBE32(&reply, frac)
        appendBE32(&reply, sec)
        appendBE32(&reply, frac)
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                reply.withUnsafeBytes { raw in
                    Darwin.sendto(timingFD, raw.baseAddress, reply.count, 0, sa, addrLen)
                }
            }
        }
    }

    private func sendUDP(fd: Int32, data: Data, to addr: inout sockaddr_in) {
        let len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                data.withUnsafeBytes { raw in
                    Darwin.sendto(fd, raw.baseAddress, data.count, 0, sa, len)
                }
            }
        }
    }

    private func disconnectSync(sendTeardown: Bool, notify: Bool, reason: String?) {
        guard !closed else { return }
        closed = true
        pendingVolumeTask?.cancel()
        pendingVolumeTask = nil
        timer?.cancel()
        timer = nil
        controlSource?.cancel()
        controlSource = nil
        timingSource?.cancel()
        timingSource = nil

        if sendTeardown && rtspFD >= 0 {
            _ = try? rtspRequest("TEARDOWN")
        }
        for fd in [rtspFD, audioFD, controlFD, timingFD] where fd >= 0 {
            Darwin.close(fd)
        }
        rtspFD = -1
        audioFD = -1
        controlFD = -1
        timingFD = -1
        streamActive = false
        streamFramesSent = 0
        buffer.clear()

        let shouldNotify = notify && notifyDisconnectOnClose
        notifyDisconnectOnClose = false
        if shouldNotify {
            let callback = onDisconnect
            DispatchQueue.main.async {
                callback?(reason)
            }
        }
    }

    private func openTCPSocket(host: String, port: UInt16, timeout: TimeInterval) throws -> (Int32, sockaddr_in, String) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RAOPError.connectionFailed("无法创建 TCP socket (\(errno))") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            Darwin.close(fd)
            throw RAOPError.connectionFailed("无效 IPv4 地址: \(host)")
        }

        let oldFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc < 0 && errno != EINPROGRESS {
            let err = errno
            Darwin.close(fd)
            throw RAOPError.connectionFailed("TCP connect 失败 (\(err))")
        }
        if rc != 0 {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let p = poll(&pfd, 1, Int32(timeout * 1000))
            if p <= 0 {
                Darwin.close(fd)
                throw RAOPError.connectionFailed("连接超时")
            }
            var soErr: Int32 = 0
            var soLen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soLen)
            if soErr != 0 {
                Darwin.close(fd)
                throw RAOPError.connectionFailed("连接被拒绝 (\(soErr))")
            }
        }
        _ = fcntl(fd, F_SETFL, oldFlags & ~O_NONBLOCK)

        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var local = sockaddr_in()
        var localLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &localLen)
            }
        }
        var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let localIP = inet_ntop(AF_INET, &local.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN)) != nil
            ? String(cString: ipBuf)
            : "0.0.0.0"
        return (fd, addr, localIP)
    }

    private func openUDPSocket() throws -> (Int32, UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw RAOPError.connectionFailed("无法创建 UDP socket (\(errno))") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let err = errno
            Darwin.close(fd)
            throw RAOPError.connectionFailed("UDP bind 失败 (\(err))")
        }
        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &boundLen)
            }
        }
        return (fd, UInt16(bigEndian: bound.sin_port))
    }

    private static func currentNTP() -> (UInt32, UInt32) {
        var tv = timeval()
        gettimeofday(&tv, nil)
        let sec = UInt32(truncatingIfNeeded: Int64(tv.tv_sec) + 2_208_988_800)
        let frac = UInt32((UInt64(tv.tv_usec) << 32) / 1_000_000)
        return (sec, frac)
    }

    private func appendBE16(_ data: inout Data, _ v: UInt16) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private func appendBE32(_ data: inout Data, _ v: UInt32) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
}

@MainActor
final class MacRAOPOutputBackend: MacDirectAirPlayBackend {
    var onStateChange: (() -> Void)?
    var onDisconnect: ((String?) -> Void)?

    private let discovery = RAOPDiscovery()
    private let buffer = RAOPPCMBuffer()
    private let tap = RAOPAudioTap()
    private var session: RAOPSession?

    private(set) var devices: [AudioOutputDevice] = []
    private(set) var activeDeviceID: String?
    private(set) var connectingDeviceID: String?
    private(set) var hasAirPlay2Targets = false
    private(set) var lastError: String?

    init() {
        discovery.onChange = { [weak self] in
            guard let self else { return }
            self.devices = self.discovery.devices.map(\.asAudioOutputDevice)
            self.hasAirPlay2Targets = self.discovery.hasAirPlay2Targets
            self.onStateChange?()
        }
    }

    func startDiscovery() {
        discovery.start()
    }

    func refreshDiscovery() {
        discovery.refresh()
    }

    func connect(deviceID: String, initialVolume: Float) async throws {
        guard let info = discovery.device(forID: deviceID) else {
            throw RAOPError.deviceNotFound
        }
        if info.requiresPassword {
            throw RAOPError.passwordRequired
        }
        disconnect()
        connectingDeviceID = deviceID
        lastError = nil
        onStateChange?()
        do {
            let resolved = try await RAOPResolver.resolve(
                serviceName: info.serviceName,
                interfaceIndex: info.interfaceIndex
            )
            let newSession = try RAOPSession(
                host: resolved.host,
                port: resolved.port,
                deviceName: info.displayName,
                codecs: info.codecs,
                encryptionTypes: info.encryptionTypes,
                buffer: buffer
            )
            newSession.onDisconnect = { [weak self] reason in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.session === newSession {
                        self.session = nil
                        self.activeDeviceID = nil
                        self.connectingDeviceID = nil
                        self.lastError = reason
                        self.onDisconnect?(reason)
                        self.onStateChange?()
                    }
                }
            }
            try await newSession.connect(initialVolume: initialVolume)
            guard connectingDeviceID == deviceID else {
                newSession.disconnect()
                return
            }
            self.session = newSession
            self.activeDeviceID = deviceID
            self.connectingDeviceID = nil
            self.onStateChange?()
        } catch {
            if connectingDeviceID == deviceID {
                connectingDeviceID = nil
            }
            lastError = error.localizedDescription
            onStateChange?()
            throw error
        }
    }

    func disconnect() {
        let old = session
        session = nil
        activeDeviceID = nil
        connectingDeviceID = nil
        old?.onDisconnect = nil
        old?.disconnect()
        buffer.clear()
        onStateChange?()
    }

    func setVolume(_ volume: Float) {
        session?.setVolume(volume)
    }

    func flush() {
        session?.flush()
    }

    func attachTap(to item: AVPlayerItem) async {
        await tap.attach(to: item, buffer: buffer)
    }

    func detachTap(from item: AVPlayerItem) {
        tap.detach(from: item)
    }
}


