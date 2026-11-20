// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// Subsonic's legacy wire format requires MD5(password + salt).
enum SubsonicMD5 {
    static func hex(_ input: Data) -> String {
        #if canImport(CryptoKit)
        let digest = Array(Insecure.MD5.hash(data: input))
        #else
        let digest = portableDigest(input)
        #endif
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    #if !canImport(CryptoKit)
    private static func portableDigest(_ data: Data) -> [UInt8] {
        let rotations = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21]
        let constants = (1...64).map { UInt32(abs(sin(Double($0))) * 4_294_967_296) }
        var message = Array(data)
        let bits = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 0, to: 64, by: 8) { message.append(UInt8(truncatingIfNeeded: bits >> shift)) }
        var state: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]

        for offset in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 16)
            for word in words.indices {
                for byte in 0..<4 {
                    words[word] |= UInt32(message[offset + word * 4 + byte]) << (byte * 8)
                }
            }
            var (a, b, c, d) = (state[0], state[1], state[2], state[3])
            for step in 0..<64 {
                let value: UInt32
                let word: Int
                switch step {
                case 0..<16: (value, word) = ((b & c) | (~b & d), step)
                case 16..<32: (value, word) = ((d & b) | (~d & c), (5 * step + 1) % 16)
                case 32..<48: (value, word) = (b ^ c ^ d, (3 * step + 5) % 16)
                default: (value, word) = (c ^ (b | ~d), (7 * step) % 16)
                }
                let shift = rotations[(step / 16) * 4 + step % 4]
                let sum = a &+ value &+ constants[step] &+ words[word]
                (a, b, c, d) = (d, b &+ ((sum << shift) | (sum >> (32 - shift))), b, c)
            }
            let updated = [a, b, c, d]
            for index in state.indices { state[index] = state[index] &+ updated[index] }
        }
        return state.flatMap { word in
            stride(from: 0, to: 32, by: 8).map { UInt8(truncatingIfNeeded: word >> $0) }
        }
    }
    #endif
}
