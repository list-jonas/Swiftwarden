import Foundation

struct Blake2b {
    private static let iv: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    ]
    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    ]

    private var h: [UInt64]
    private var t: UInt64 = 0
    private var buf: [UInt8] = []
    private let outLen: Int

    init(outLen: Int) {
        self.outLen = outLen
        h = Blake2b.iv
        h[0] ^= 0x0101_0000 ^ UInt64(outLen)
        buf.reserveCapacity(128)
    }

    static func hash(_ data: [UInt8], outLen: Int) -> [UInt8] {
        var b = Blake2b(outLen: outLen)
        b.update(data)
        return b.finalize()
    }

    mutating func update(_ data: [UInt8]) {
        var i = 0
        while i < data.count {
            if buf.count == 128 {
                t &+= 128
                compress(last: false)
                buf.removeAll(keepingCapacity: true)
            }
            let n = min(128 - buf.count, data.count - i)
            buf.append(contentsOf: data[i ..< i + n])
            i += n
        }
    }

    mutating func finalize() -> [UInt8] {
        t &+= UInt64(buf.count)
        buf.append(contentsOf: [UInt8](repeating: 0, count: 128 - buf.count))
        compress(last: true)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for w in h { for k in 0 ..< 8 { out.append(UInt8(truncatingIfNeeded: w >> (8 * UInt64(k)))) } }
        return Array(out.prefix(outLen))
    }

    @inline(__always) private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }

    private mutating func compress(last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        buf.withUnsafeBytes { p in for i in 0 ..< 16 { m[i] = UInt64(littleEndian: p.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) } }
        var v = h + Blake2b.iv
        v[12] ^= t
        if last { v[14] = ~v[14] }
        func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x; v[d] = Blake2b.rotr(v[d] ^ v[a], 32)
            v[c] = v[c] &+ v[d]; v[b] = Blake2b.rotr(v[b] ^ v[c], 24)
            v[a] = v[a] &+ v[b] &+ y; v[d] = Blake2b.rotr(v[d] ^ v[a], 16)
            v[c] = v[c] &+ v[d]; v[b] = Blake2b.rotr(v[b] ^ v[c], 63)
        }
        for r in 0 ..< 12 {
            let s = Blake2b.sigma[r]
            g(0, 4, 8, 12, m[s[0]], m[s[1]]); g(1, 5, 9, 13, m[s[2]], m[s[3]])
            g(2, 6, 10, 14, m[s[4]], m[s[5]]); g(3, 7, 11, 15, m[s[6]], m[s[7]])
            g(0, 5, 10, 15, m[s[8]], m[s[9]]); g(1, 6, 11, 12, m[s[10]], m[s[11]])
            g(2, 7, 8, 13, m[s[12]], m[s[13]]); g(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0 ..< 8 { h[i] ^= v[i] ^ v[i + 8] }
    }
}

public enum Argon2id {
    private static let blockWords = 128

    private struct Mem: @unchecked Sendable { let p: UnsafeMutablePointer<UInt64> }

    @inline(__always) private static func le32(_ v: Int) -> [UInt8] {
        let u = UInt32(truncatingIfNeeded: v)
        return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8(u >> 24)]
    }

    static func hPrime(_ outLen: Int, _ input: [UInt8]) -> [UInt8] {
        if outLen <= 64 {
            var b = Blake2b(outLen: outLen)
            b.update(le32(outLen)); b.update(input)
            return b.finalize()
        }
        var b = Blake2b(outLen: 64)
        b.update(le32(outLen)); b.update(input)
        var v = b.finalize()
        var out = Array(v[0 ..< 32])
        let r = (outLen + 31) / 32 - 2
        for _ in 1 ..< r {
            v = Blake2b.hash(v, outLen: 64)
            out += v[0 ..< 32]
        }
        out += Blake2b.hash(v, outLen: outLen - 32 * r)
        return out
    }

    @inline(__always) private static func fBlaMka(_ x: UInt64, _ y: UInt64) -> UInt64 {
        let m: UInt64 = 0xffff_ffff
        return x &+ y &+ 2 &* ((x & m) &* (y & m))
    }

    @inline(__always) private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }

    @inline(__always) private static func gb(_ v: UnsafeMutablePointer<UInt64>, _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        var va = v[a], vb = v[b], vc = v[c], vd = v[d]
        va = fBlaMka(va, vb); vd = rotr(vd ^ va, 32); vc = fBlaMka(vc, vd); vb = rotr(vb ^ vc, 24)
        va = fBlaMka(va, vb); vd = rotr(vd ^ va, 16); vc = fBlaMka(vc, vd); vb = rotr(vb ^ vc, 63)
        v[a] = va; v[b] = vb; v[c] = vc; v[d] = vd
    }

    @inline(__always) private static func round(_ v: UnsafeMutablePointer<UInt64>, _ i: UnsafePointer<Int>) {
        gb(v, i[0], i[4], i[8], i[12]); gb(v, i[1], i[5], i[9], i[13])
        gb(v, i[2], i[6], i[10], i[14]); gb(v, i[3], i[7], i[11], i[15])
        gb(v, i[0], i[5], i[10], i[15]); gb(v, i[1], i[6], i[11], i[12])
        gb(v, i[2], i[7], i[8], i[13]); gb(v, i[3], i[4], i[9], i[14])
    }

    private static let idx: [Int] = {
        var a = [Int]()
        for r in 0 ..< 8 { for j in 0 ..< 16 { a.append(16 * r + j) } }
        for c in 0 ..< 8 { for j in 0 ..< 8 { a.append(2 * c + 16 * j); a.append(2 * c + 16 * j + 1) } }
        return a
    }()

    private static func fill(_ prev: UnsafeMutablePointer<UInt64>, _ ref: UnsafeMutablePointer<UInt64>, _ next: UnsafeMutablePointer<UInt64>,
                             _ withXor: Bool, _ r: UnsafeMutablePointer<UInt64>, _ tmp: UnsafeMutablePointer<UInt64>, _ ix: UnsafePointer<Int>) {
        for i in 0 ..< blockWords {
            r[i] = ref[i] ^ prev[i]
            tmp[i] = withXor ? r[i] ^ next[i] : r[i]
        }
        for k in 0 ..< 16 { round(r, ix + 16 * k) }
        for i in 0 ..< blockWords { next[i] = tmp[i] ^ r[i] }
    }

    public static func hash(password: [UInt8], salt: [UInt8], iterations t: Int, memoryKiB m: Int, parallelism p: Int,
                            outLen: Int = 32, secret: [UInt8] = [], ad: [UInt8] = []) -> [UInt8] {
        var h0in = le32(p) + le32(outLen) + le32(m) + le32(t) + le32(0x13) + le32(2)
        h0in += le32(password.count) + password + le32(salt.count) + salt
        h0in += le32(secret.count) + secret + le32(ad.count) + ad
        let h0 = Blake2b.hash(h0in, outLen: 64)

        let segLen = max(m, 8 * p) / (4 * p)
        let laneLen = segLen * 4
        let total = laneLen * p
        let mem = UnsafeMutablePointer<UInt64>.allocate(capacity: total * blockWords)
        mem.initialize(repeating: 0, count: total * blockWords)
        defer { mem.deallocate() }
        let box = Mem(p: mem)

        for lane in 0 ..< p {
            for j in 0 ..< 2 {
                let bytes = hPrime(1024, h0 + le32(j) + le32(lane))
                let blk = mem + (lane * laneLen + j) * blockWords
                bytes.withUnsafeBytes { b in for w in 0 ..< blockWords { blk[w] = UInt64(littleEndian: b.loadUnaligned(fromByteOffset: w * 8, as: UInt64.self)) } }
            }
        }

        for pass in 0 ..< t {
            for slice in 0 ..< 4 {
                DispatchQueue.concurrentPerform(iterations: p) { lane in
                    fillSegment(box.p, pass: pass, slice: slice, lane: lane, lanes: p, segLen: segLen, laneLen: laneLen, total: total, passes: t)
                }
            }
        }

        var final = [UInt64](repeating: 0, count: blockWords)
        for lane in 0 ..< p {
            let blk = mem + (lane * laneLen + laneLen - 1) * blockWords
            for w in 0 ..< blockWords { final[w] ^= blk[w] }
        }
        var bytes = [UInt8](repeating: 0, count: 1024)
        for w in 0 ..< blockWords { for k in 0 ..< 8 { bytes[w * 8 + k] = UInt8(truncatingIfNeeded: final[w] >> (8 * UInt64(k))) } }
        return hPrime(outLen, bytes)
    }

    private static func fillSegment(_ mem: UnsafeMutablePointer<UInt64>, pass: Int, slice: Int, lane: Int, lanes: Int,
                                    segLen: Int, laneLen: Int, total: Int, passes: Int) {
        let scratch = UnsafeMutablePointer<UInt64>.allocate(capacity: blockWords * 5)
        scratch.initialize(repeating: 0, count: blockWords * 5)
        defer { scratch.deallocate() }
        let ixp = UnsafeMutablePointer<Int>.allocate(capacity: idx.count)
        ixp.initialize(from: idx, count: idx.count)
        defer { ixp.deallocate() }
        let ix = UnsafePointer(ixp)
        let r = scratch, tmp = scratch + blockWords, zero = scratch + 2 * blockWords
        let input = scratch + 3 * blockWords, addr = scratch + 4 * blockWords

        let indep = pass == 0 && slice < 2
        if indep {
            input[0] = UInt64(pass); input[1] = UInt64(lane); input[2] = UInt64(slice)
            input[3] = UInt64(total); input[4] = UInt64(passes); input[5] = 2
        }
        func nextAddresses() {
            input[6] &+= 1
            fill(zero, input, addr, false, r, tmp, ix)
            fill(zero, addr, addr, false, r, tmp, ix)
        }
        var start = 0
        if pass == 0 && slice == 0 {
            start = 2
            if indep { nextAddresses() }
        }
        var cur = lane * laneLen + slice * segLen + start
        var prev = cur % laneLen == 0 ? cur + laneLen - 1 : cur - 1
        for i in start ..< segLen {
            if cur % laneLen == 1 { prev = cur - 1 }
            let rand: UInt64
            if indep {
                if i % 128 == 0 { nextAddresses() }
                rand = addr[i % 128]
            } else {
                rand = mem[prev * blockWords]
            }
            var refLane = Int((rand >> 32) % UInt64(lanes))
            if pass == 0 && slice == 0 { refLane = lane }
            let same = refLane == lane
            let area: Int
            if pass == 0 {
                if slice == 0 { area = i - 1 }
                else if same { area = slice * segLen + i - 1 }
                else { area = slice * segLen + (i == 0 ? -1 : 0) }
            } else {
                area = same ? laneLen - segLen + i - 1 : laneLen - segLen + (i == 0 ? -1 : 0)
            }
            var rel = rand & 0xffff_ffff
            rel = (rel &* rel) >> 32
            let relPos = UInt64(area) - 1 - ((UInt64(area) &* rel) >> 32)
            let startPos = pass != 0 ? (slice == 3 ? 0 : (slice + 1) * segLen) : 0
            let refIdx = (UInt64(startPos) + relPos) % UInt64(laneLen)
            let refBlock = mem + (refLane * laneLen + Int(refIdx)) * blockWords
            fill(mem + prev * blockWords, refBlock, mem + cur * blockWords, pass != 0, r, tmp, ix)
            cur += 1; prev += 1
        }
    }
}
