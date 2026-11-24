import Foundation
import AVFoundation
import CommonCrypto

// MARK: - Playlist model

/// A parsed HLS media playlist: segment timeline plus what's needed to read each segment's audio.
struct HLSMediaPlaylist {
    struct Key: Equatable {
        var method: String
        var url: URL?
        var iv: Data?
    }

    struct Segment {
        var url: URL
        var start: Double
        var duration: Double
        var sequence: Int
        var key: Key?
        var map: URL?
        var byteRange: Bool
    }

    private(set) var segments: [Segment] = []
    private(set) var ended = false
    private var positions: [URL: Int] = [:]

    init(text: String, base: URL) {
        var sequence = 0
        var key: Key?
        var map: URL?
        var duration: Double?
        var byteRange = false
        var start = 0.0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                    sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
                } else if line.hasPrefix("#EXTINF:") {
                    duration = Double(line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "")
                } else if line.hasPrefix("#EXT-X-KEY:") {
                    let a = Self.attributes(line)
                    let method = a["METHOD"] ?? "NONE"
                    key = method == "NONE" ? nil : Key(method: method, url: a["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }, iv: a["IV"].flatMap(Self.hex))
                } else if line.hasPrefix("#EXT-X-MAP:") {
                    map = Self.attributes(line)["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
                } else if line.hasPrefix("#EXT-X-BYTERANGE") {
                    byteRange = true
                } else if line.hasPrefix("#EXT-X-ENDLIST") {
                    ended = true
                }
                continue
            }
            guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
            let d = duration ?? 0
            positions[url] = segments.count
            segments.append(Segment(url: url, start: start, duration: d, sequence: sequence, key: key, map: map, byteRange: byteRange))
            start += d
            sequence += 1
            duration = nil
            byteRange = false
        }
    }

    func index(of url: URL) -> Int? { positions[url] }

    func index(at time: Double) -> Int? {
        segments.lastIndex { $0.start <= time + 0.01 } ?? (segments.isEmpty ? nil : 0)
    }

    static func attributes(_ line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var out: [String: String] = [:]
        var key = "", value = "", inKey = true, quoted = false
        for c in line[line.index(after: colon)...] {
            if inKey {
                if c == "=" { inKey = false } else if c != "," { key.append(c) }
            } else if c == "\"" {
                quoted.toggle()
            } else if c == ",", !quoted {
                out[key.trimmingCharacters(in: .whitespaces).uppercased()] = value
                key = ""; value = ""; inKey = true
            } else {
                value.append(c)
            }
        }
        if !key.isEmpty { out[key.trimmingCharacters(in: .whitespaces).uppercased()] = value }
        return out
    }

    private static func hex(_ s: String) -> Data? {
        var h = s.lowercased()
        if h.hasPrefix("0x") { h.removeFirst(2) }
        guard h.count % 2 == 0 else { return nil }
        var d = Data()
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
            d.append(b)
            i = j
        }
        return d
    }
}

// MARK: - Feed

/// Supplies the audio of an HLS stream played through VideoProxy, in step with playback, so
/// subtitles work without capturing the app's sound. Segments come from the proxy cache (the
/// player has usually fetched them already), are decrypted (AES-128), demuxed (MPEG-TS, packed
/// AAC or fragmented MP4) and decoded to PCM; each slice is handed over once playback reaches it.
final class HLSAudioFeed {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Called once on the main queue when this stream's audio can't be read here.
    var onFailure: ((String) -> Void)?

    private let proxied: URL
    private let time: () -> Double
    private let queue = DispatchQueue(label: "fa.hlsaudio")
    private var timer: Timer?
    private var stopped = false

    // Queue state
    private var pending: [(start: Double, buffer: AVAudioPCMBuffer)] = []
    private var nextTime = -1.0
    private var deliveredTo = -1.0
    private var busy = false
    private var failures = 0
    private var waitedForPlaylist = 0
    private var keys: [URL: Data] = [:]
    private var maps: [URL: Data] = [:]
    private let aac = ADTSDecoder()

    init(proxied: URL, time: @escaping () -> Double) {
        self.proxied = proxied
        self.time = time
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = self.time()
            self.queue.async { self.advance(to: t) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        queue.async { self.stopped = true; self.pending = [] }
    }

    private func fail(_ reason: String) {
        guard !stopped else { return }
        stopped = true
        pending = []
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = nil
            self.onFailure?(reason)
        }
    }

    private func advance(to t: Double) {
        guard !stopped, t.isFinite else { return }
        // Seek: drop what was prepared and start decoding where playback now is.
        if deliveredTo < 0 || t < deliveredTo - 1.5 || t > deliveredTo + 4 {
            pending = []
            nextTime = t
            deliveredTo = t
            aac.reset()
        }
        while let first = pending.first, first.start <= t {
            pending.removeFirst()
            let end = first.start + Double(first.buffer.frameLength) / first.buffer.format.sampleRate
            if end > deliveredTo - 0.3 { onBuffer?(first.buffer) }
            deliveredTo = max(deliveredTo, end)
        }
        deliveredTo = max(deliveredTo, t)
        let preparedTo = pending.last.map { $0.start + Double($0.buffer.frameLength) / $0.buffer.format.sampleRate } ?? nextTime
        guard !busy, preparedTo < t + 8 else { return }
        busy = true
        VideoProxy.shared.hlsAudioPlaylist(for: proxied) { [weak self] playlist in
            self?.queue.async { self?.loadNext(playlist) }
        }
    }

    private func loadNext(_ playlist: HLSMediaPlaylist?) {
        guard !stopped else { return }
        guard let playlist, !playlist.segments.isEmpty else {
            busy = false
            waitedForPlaylist += 1
            if waitedForPlaylist > 50 { fail("no playlist") }
            return
        }
        guard playlist.ended else { fail("live stream"); return }
        guard let i = playlist.index(at: nextTime + 0.05) else { busy = false; return }
        let seg = playlist.segments[i]
        guard seg.start + seg.duration > nextTime + 0.05 else { busy = false; return }
        guard !seg.byteRange else { fail("byte-range segments"); return }
        if let key = seg.key, key.method != "AES-128" { fail("encryption \(key.method)"); return }
        fetch(seg) { [weak self] data in
            self?.queue.async { self?.decode(data, segment: seg) }
        }
    }

    private func fetch(_ seg: HLSMediaPlaylist.Segment, completion: @escaping (Data?) -> Void) {
        let proxy = VideoProxy.shared
        let group = DispatchGroup()
        var key: Data? = seg.key?.url.flatMap { keys[$0] }
        var map: Data? = seg.map.flatMap { maps[$0] }
        var body: Data?
        if let u = seg.key?.url, key == nil {
            group.enter()
            proxy.hlsData(for: proxied, url: u) { key = $0; group.leave() }
        }
        if let u = seg.map, map == nil {
            group.enter()
            proxy.hlsData(for: proxied, url: u) { map = $0; group.leave() }
        }
        group.enter()
        proxy.hlsData(for: proxied, url: seg.url) { body = $0; group.leave() }
        group.notify(queue: queue) { [weak self] in
            guard let self, var data = body else { completion(nil); return }
            if let u = seg.key?.url, let key { self.keys[u] = key }
            if let u = seg.map, let map { self.maps[u] = map }
            if let k = seg.key {
                guard let key, key.count == 16 else { completion(nil); return }
                var iv = k.iv ?? Data(count: 16)
                if k.iv == nil { withUnsafeBytes(of: UInt64(seg.sequence).bigEndian) { iv.replaceSubrange(8..<16, with: $0) } }
                guard let plain = AES128.decrypt(data, key: key, iv: iv) else { completion(nil); return }
                data = plain
            }
            if let map { data = map + data }
            completion(data)
        }
    }

    private func decode(_ data: Data?, segment seg: HLSMediaPlaylist.Segment) {
        busy = false
        guard !stopped else { return }
        guard let data else {
            failures += 1
            if failures >= 3 { fail("download") }
            return
        }
        var pcm: [AVAudioPCMBuffer] = []
        if let es = MPEGTS.audioStream(data) {
            pcm = aac.decode(es)
        } else if let es = PackedAudio.adts(data) {
            pcm = aac.decode(es)
        } else if FragmentedMP4.looksLike(data) {
            pcm = FragmentedMP4.decode(data)
        }
        guard !pcm.isEmpty else {
            failures += 1
            NSLog("[subs] hls audio: no decodable audio in segment %d (%d bytes)", seg.sequence, data.count)
            if failures >= 2 { fail("unsupported audio") }
            nextTime = seg.start + seg.duration
            return
        }
        failures = 0
        var t = seg.start
        for b in Self.slices(pcm, seconds: 0.25) {
            if t + Double(b.frameLength) / b.format.sampleRate > nextTime - 0.3 { pending.append((t, b)) }
            t += Double(b.frameLength) / b.format.sampleRate
        }
        nextTime = seg.start + seg.duration
    }

    /// Re-cuts decoded audio into even slices so it can be released in small steps.
    private static func slices(_ buffers: [AVAudioPCMBuffer], seconds: Double) -> [AVAudioPCMBuffer] {
        guard let format = buffers.first?.format else { return [] }
        let size = AVAudioFrameCount(format.sampleRate * seconds)
        var out: [AVAudioPCMBuffer] = []
        var current: AVAudioPCMBuffer?
        for b in buffers where b.format == format {
            var offset: AVAudioFrameCount = 0
            while offset < b.frameLength {
                if current == nil { current = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: size) }
                guard let cur = current else { return out }
                let n = min(size - cur.frameLength, b.frameLength - offset)
                for ch in 0..<Int(format.channelCount) {
                    guard let src = b.floatChannelData?[ch], let dst = cur.floatChannelData?[ch] else { continue }
                    (dst + Int(cur.frameLength)).update(from: src + Int(offset), count: Int(n))
                }
                cur.frameLength += n
                offset += n
                if cur.frameLength == size { out.append(cur); current = nil }
            }
        }
        if let cur = current, cur.frameLength > 0 { out.append(cur) }
        return out
    }
}

// MARK: - Decryption

enum AES128 {
    static func decrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress, d.baseAddress, data.count, o.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = moved
        return out
    }
}

// MARK: - Demuxing

enum MPEGTS {
    /// The AAC (ADTS) elementary stream of the first audio program in a transport stream.
    /// Tolerates junk before the first packet (some sites prepend an image header to segments).
    static func audioStream(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard let start = syncOffset(bytes) else { return nil }
        var pmtPID = -1, audioPID = -1
        var es = Data()
        var pos = start
        while pos + 188 <= bytes.count {
            defer { pos += 188 }
            guard bytes[pos] == 0x47 else { continue }
            let unitStart = bytes[pos + 1] & 0x40 != 0
            let pid = Int(bytes[pos + 1] & 0x1F) << 8 | Int(bytes[pos + 2])
            let adaptation = (bytes[pos + 3] >> 4) & 0x3
            var p = pos + 4
            if adaptation == 2 { continue }
            if adaptation == 3 { p += 1 + Int(bytes[p]) }
            guard p < pos + 188 else { continue }
            if pid == 0, unitStart {
                p += 1 + Int(bytes[p])
                // PAT: first program entry with a non-zero number.
                let sectionLength = Int(bytes[p + 1] & 0x0F) << 8 | Int(bytes[p + 2])
                var q = p + 8
                let end = min(p + 3 + sectionLength - 4, pos + 188)
                while q + 4 <= end {
                    let number = Int(bytes[q]) << 8 | Int(bytes[q + 1])
                    if number != 0 { pmtPID = Int(bytes[q + 2] & 0x1F) << 8 | Int(bytes[q + 3]); break }
                    q += 4
                }
            } else if pid == pmtPID, unitStart, audioPID < 0 {
                p += 1 + Int(bytes[p])
                let sectionLength = Int(bytes[p + 1] & 0x0F) << 8 | Int(bytes[p + 2])
                let infoLength = Int(bytes[p + 10] & 0x0F) << 8 | Int(bytes[p + 11])
                var q = p + 12 + infoLength
                let end = min(p + 3 + sectionLength - 4, pos + 188)
                while q + 5 <= end {
                    let type = bytes[q]
                    let esPID = Int(bytes[q + 1] & 0x1F) << 8 | Int(bytes[q + 2])
                    let esInfo = Int(bytes[q + 3] & 0x0F) << 8 | Int(bytes[q + 4])
                    if type == 0x0F { audioPID = esPID; break }
                    q += 5 + esInfo
                }
            } else if pid == audioPID {
                if unitStart {
                    guard p + 9 <= pos + 188, bytes[p] == 0, bytes[p + 1] == 0, bytes[p + 2] == 1 else { continue }
                    p += 9 + Int(bytes[p + 8])
                }
                if p < pos + 188 { es.append(contentsOf: bytes[p..<(pos + 188)]) }
            }
        }
        return es.isEmpty ? nil : es
    }

    private static func syncOffset(_ b: [UInt8]) -> Int? {
        let limit = min(b.count - 188 * 3, 64 * 1024)
        guard limit >= 0 else { return nil }
        for i in 0...limit where b[i] == 0x47 && b[i + 188] == 0x47 && b[i + 376] == 0x47 { return i }
        return nil
    }
}

enum PackedAudio {
    /// Raw ADTS audio segments (.aac), optionally led by an ID3 tag.
    static func adts(_ data: Data) -> Data? {
        let b = [UInt8](data.prefix(64 * 1024))
        var i = 0
        if b.count > 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 {
            let size = Int(b[6] & 0x7F) << 21 | Int(b[7] & 0x7F) << 14 | Int(b[8] & 0x7F) << 7 | Int(b[9] & 0x7F)
            i = 10 + size
        }
        guard i + 2 < b.count, b[i] == 0xFF, b[i + 1] & 0xF6 == 0xF0 else { return nil }
        return data.subdata(in: data.startIndex + i..<data.endIndex)
    }
}

enum FragmentedMP4 {
    static func looksLike(_ data: Data) -> Bool {
        guard data.count > 12 else { return false }
        let type = String(decoding: data[data.startIndex + 4..<data.startIndex + 8], as: UTF8.self)
        return ["ftyp", "styp", "moof", "sidx"].contains(type)
    }

    /// Reads the audio of an init section + media segment with AVAssetReader.
    static func decode(_ data: Data) -> [AVAudioPCMBuffer] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hls-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return [] }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                       AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var out: [AVAudioPCMBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            if let b = AudioPCM.buffer(from: sample), let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: b.format.sampleRate, channels: b.format.channelCount, interleaved: false),
               let converted = ADTSDecoder.convert(b, to: f) {
                out.append(converted)
            }
        }
        return out
    }
}

// MARK: - AAC decoding

/// Decodes ADTS AAC frames to non-interleaved Float32 PCM, keeping decoder state between segments.
final class ADTSDecoder {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    func reset() { converter?.reset() }

    func decode(_ es: Data) -> [AVAudioPCMBuffer] {
        let b = [UInt8](es)
        var frames: [(offset: Int, length: Int)] = []
        var header: (rate: Double, channels: UInt32, object: UInt32, freqIndex: UInt8, config: UInt8)?
        var i = 0
        while i + 7 <= b.count {
            guard b[i] == 0xFF, b[i + 1] & 0xF6 == 0xF0 else { i += 1; continue }
            let protectionAbsent = b[i + 1] & 0x01 == 1
            let object = UInt32((b[i + 2] >> 6) & 0x3) + 1
            let freqIndex = (b[i + 2] >> 2) & 0xF
            let config = ((b[i + 2] & 0x1) << 2) | (b[i + 3] >> 6)
            let length = Int(b[i + 3] & 0x3) << 11 | Int(b[i + 4]) << 3 | Int(b[i + 5] >> 5)
            let headerSize = protectionAbsent ? 7 : 9
            guard length > headerSize, i + length <= b.count, let rate = Self.rates[safe: Int(freqIndex)] else { i += 1; continue }
            if header == nil { header = (rate, UInt32(max(config, 1)), object, freqIndex, config) }
            frames.append((i + headerSize, length - headerSize))
            i += length
        }
        guard let h = header, !frames.isEmpty else { return [] }
        if converter == nil || inputFormat?.sampleRate != h.rate || inputFormat?.channelCount != h.channels {
            var asbd = AudioStreamBasicDescription(mSampleRate: h.rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                                   mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                                   mChannelsPerFrame: h.channels, mBitsPerChannel: 0, mReserved: 0)
            guard let inF = AVAudioFormat(streamDescription: &asbd),
                  let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: h.rate, channels: h.channels, interleaved: false),
                  let c = AVAudioConverter(from: inF, to: outF) else { return [] }
            // AudioSpecificConfig: object type, sampling index, channel configuration.
            let asc = UInt16(min(h.object, 2)) << 11 | UInt16(h.freqIndex) << 7 | UInt16(h.config) << 3
            c.magicCookie = Data([UInt8(asc >> 8), UInt8(asc & 0xFF)])
            converter = c
            inputFormat = inF
            outputFormat = outF
        }
        guard let converter, let inputFormat, let outputFormat else { return [] }
        let maxPacket = frames.map(\.length).max() ?? 0
        let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: AVAudioPacketCount(frames.count), maximumPacketSize: maxPacket)
        var offset = 0
        b.withUnsafeBytes { raw in
            for (k, f) in frames.enumerated() {
                (compressed.data + offset).copyMemory(from: raw.baseAddress! + f.offset, byteCount: f.length)
                compressed.packetDescriptions?[k] = AudioStreamPacketDescription(mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(f.length))
                offset += f.length
            }
        }
        compressed.packetCount = AVAudioPacketCount(frames.count)
        compressed.byteLength = UInt32(offset)

        var out: [AVAudioPCMBuffer] = []
        var supplied = false
        while true {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frames.count * 1024 + 2048)) else { break }
            var error: NSError?
            let status = converter.convert(to: pcm, error: &error) { _, inStatus in
                if supplied { inStatus.pointee = .noDataNow; return nil }
                supplied = true
                inStatus.pointee = .haveData
                return compressed
            }
            if pcm.frameLength > 0 { out.append(pcm) }
            if status != .haveData || pcm.frameLength == 0 {
                if status == .error { NSLog("[subs] aac decode error: %@", error?.localizedDescription ?? "-") }
                break
            }
        }
        return out
    }

    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let c = AVAudioConverter(from: buffer.format, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else { return nil }
        try? c.convert(to: out, from: buffer)
        return out.frameLength > 0 ? out : nil
    }

    private static let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
}
