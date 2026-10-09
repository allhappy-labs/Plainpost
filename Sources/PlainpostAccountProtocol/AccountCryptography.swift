import Foundation

enum AccountSHA256 {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ data: Data) -> Data {
        var bytes = Array(data)
        let bitCount = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((bitCount >> UInt64(shift)) & 0xff)) }

        var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let start = offset + index * 4
                words[index] = UInt32(bytes[start]) << 24 | UInt32(bytes[start + 1]) << 16 | UInt32(bytes[start + 2]) << 8 | UInt32(bytes[start + 3])
            }
            for index in 16..<64 {
                let s0 = words[index - 15].rotatedRight(7) ^ words[index - 15].rotatedRight(18) ^ (words[index - 15] >> 3)
                let s1 = words[index - 2].rotatedRight(17) ^ words[index - 2].rotatedRight(19) ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var working = state
            for index in 0..<64 {
                let sum1 = working[4].rotatedRight(6) ^ working[4].rotatedRight(11) ^ working[4].rotatedRight(25)
                let choice = (working[4] & working[5]) ^ (~working[4] & working[6])
                let temporary1 = working[7] &+ sum1 &+ choice &+ constants[index] &+ words[index]
                let sum0 = working[0].rotatedRight(2) ^ working[0].rotatedRight(13) ^ working[0].rotatedRight(22)
                let majority = (working[0] & working[1]) ^ (working[0] & working[2]) ^ (working[1] & working[2])
                let temporary2 = sum0 &+ majority
                working = [temporary1 &+ temporary2, working[0], working[1], working[2], working[3] &+ temporary1, working[4], working[5], working[6]]
            }
            for index in state.indices { state[index] &+= working[index] }
        }
        return Data(state.flatMap { word in [UInt8(word >> 24), UInt8((word >> 16) & 0xff), UInt8((word >> 8) & 0xff), UInt8(word & 0xff)] })
    }
}

enum AccountP256SEC1Validator {
    private static let modulus = words("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF")
    private static let curveB = words("5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B")

    static func isValidUncompressedPoint(_ encoded: Data) -> Bool {
        guard encoded.count == 65, encoded.first == 0x04 else { return false }
        let x = coordinate(Data(encoded[1..<33]))
        let y = coordinate(Data(encoded[33..<65]))
        guard compare(x, modulus) < 0, compare(y, modulus) < 0 else { return false }
        let ySquared = multiplyMod(y, y)
        let xCubed = multiplyMod(multiplyMod(x, x), x)
        let threeX = addMod(addMod(x, x), x)
        return ySquared == addMod(subtractMod(xCubed, threeX), curveB)
    }

    private static func coordinate(_ data: Data) -> [UInt16] {
        let bytes = Array(data)
        return (0..<16).map { index in
            let offset = 30 - index * 2
            return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }
    }

    private static func words(_ hex: String) -> [UInt16] {
        var result: [UInt16] = []
        var end = hex.endIndex
        while end > hex.startIndex {
            let start = hex.index(end, offsetBy: -4)
            result.append(UInt16(hex[start..<end], radix: 16)!)
            end = start
        }
        return result
    }

    private static func compare(_ lhs: [UInt16], _ rhs: [UInt16]) -> Int {
        for index in stride(from: max(lhs.count, rhs.count) - 1, through: 0, by: -1) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }

    private static func subtract(_ lhs: [UInt16], _ rhs: [UInt16]) -> [UInt16] {
        var result = lhs
        var borrow: Int64 = 0
        for index in result.indices {
            let difference = Int64(result[index]) - Int64(index < rhs.count ? rhs[index] : 0) - borrow
            result[index] = UInt16(difference < 0 ? difference + 65_536 : difference)
            borrow = difference < 0 ? 1 : 0
        }
        return result
    }

    private static func addMod(_ lhs: [UInt16], _ rhs: [UInt16]) -> [UInt16] {
        var result = [UInt16](repeating: 0, count: 17)
        var carry: UInt32 = 0
        for index in 0..<16 {
            let sum = UInt32(lhs[index]) + UInt32(rhs[index]) + carry
            result[index] = UInt16(sum & 0xffff)
            carry = sum >> 16
        }
        result[16] = UInt16(carry)
        let extendedModulus = modulus + [0]
        if compare(result, extendedModulus) >= 0 { result = subtract(result, extendedModulus) }
        return Array(result.prefix(16))
    }

    private static func subtractMod(_ lhs: [UInt16], _ rhs: [UInt16]) -> [UInt16] {
        if compare(lhs, rhs) >= 0 { return Array(subtract(lhs, rhs).prefix(16)) }
        return Array(subtract(modulus, subtract(rhs, lhs)).prefix(16))
    }

    private static func multiplyMod(_ lhs: [UInt16], _ rhs: [UInt16]) -> [UInt16] {
        var accumulated = [UInt64](repeating: 0, count: 33)
        for left in 0..<16 {
            for right in 0..<16 { accumulated[left + right] += UInt64(lhs[left]) * UInt64(rhs[right]) }
        }
        for index in 0..<32 {
            accumulated[index + 1] += accumulated[index] >> 16
            accumulated[index] &= 0xffff
        }
        let product = accumulated.prefix(32).map(UInt16.init)
        var remainder = [UInt16](repeating: 0, count: 17)
        let extendedModulus = modulus + [0]
        for bit in stride(from: 511, through: 0, by: -1) {
            var carry: UInt16 = 0
            for index in remainder.indices {
                let nextCarry = remainder[index] >> 15
                remainder[index] = remainder[index] << 1 | carry
                carry = nextCarry
            }
            let word = bit / 16
            remainder[0] |= (product[word] >> UInt16(bit % 16)) & 1
            if compare(remainder, extendedModulus) >= 0 { remainder = subtract(remainder, extendedModulus) }
        }
        return Array(remainder.prefix(16))
    }
}

private extension UInt32 {
    func rotatedRight(_ count: UInt32) -> UInt32 { self >> count | self << (32 - count) }
}
