import Foundation
import Testing

@testable import STTLabCore

@Suite("WAVFile tests")
struct WAVFileTests {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("STTLabCoreTests")
            .appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func writeAndReadFloat32IsBitExact() throws {
        let url = tempURL("bit_exact_\(UUID().uuidString).wav")
        defer { cleanup(url) }

        let original: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0, 0.123456, -0.999]
        try WAVFile.writeFloat32Mono16k(samples: original, to: url)

        let (read, sampleRate) = try WAVFile.readFloat32Mono(url: url)
        #expect(sampleRate == 16000.0)
        #expect(read.count == original.count)

        for i in 0 ..< original.count {
            #expect(read[i].bitPattern == original[i].bitPattern,
                    "Sample \(i): expected \(original[i]), got \(read[i])")
        }
    }

    @Test func writeCreatesReadableFile() throws {
        let url = tempURL("readable_\(UUID().uuidString).wav")
        defer { cleanup(url) }

        try WAVFile.writeFloat32Mono16k(samples: [0.1, 0.2, 0.3], to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func int16WAVDataHasCorrectHeader() throws {
        let samples: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0]
        let data = WAVFile.int16WAVData(samples: samples)

        // 44 byte header + 5 samples * 2 bytes = 54
        #expect(data.count == 54)

        // "RIFF"
        #expect(data[0] == 0x52)
        #expect(data[1] == 0x49)
        #expect(data[2] == 0x46)
        #expect(data[3] == 0x46)

        // File size (little-endian): 54 - 8 = 46
        let fileSize = UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
        #expect(fileSize == 46)

        // "WAVE"
        #expect(data[8] == 0x57)
        #expect(data[9] == 0x41)
        #expect(data[10] == 0x56)
        #expect(data[11] == 0x45)

        // "fmt "
        #expect(data[12] == 0x66)
        #expect(data[13] == 0x6D)
        #expect(data[14] == 0x74)
        #expect(data[15] == 0x20)

        // fmt chunk size = 16
        let fmtSize = UInt32(data[16]) | UInt32(data[17]) << 8 | UInt32(data[18]) << 16 | UInt32(data[19]) << 24
        #expect(fmtSize == 16)

        // PCM format = 1
        let format = UInt16(data[20]) | UInt16(data[21]) << 8
        #expect(format == 1)

        // Channels = 1
        let channels = UInt16(data[22]) | UInt16(data[23]) << 8
        #expect(channels == 1)

        // Sample rate = 16000
        let sr = UInt32(data[24]) | UInt32(data[25]) << 8 | UInt32(data[26]) << 16 | UInt32(data[27]) << 24
        #expect(sr == 16000)

        // Byte rate = 32000 (16000 * 1 * 2)
        let byteRate = UInt32(data[28]) | UInt32(data[29]) << 8 | UInt32(data[30]) << 16 | UInt32(data[31]) << 24
        #expect(byteRate == 32000)

        // Block align = 2
        let blockAlign = UInt16(data[32]) | UInt16(data[33]) << 8
        #expect(blockAlign == 2)

        // Bits per sample = 16
        let bitsPerSample = UInt16(data[34]) | UInt16(data[35]) << 8
        #expect(bitsPerSample == 16)

        // "data"
        #expect(data[36] == 0x64)
        #expect(data[37] == 0x61)
        #expect(data[38] == 0x74)
        #expect(data[39] == 0x61)

        // Data chunk size = 10
        let dataSize = UInt32(data[40]) | UInt32(data[41]) << 8 | UInt32(data[42]) << 16 | UInt32(data[43]) << 24
        #expect(dataSize == 10)
    }

    @Test func int16WAVDataClampsSamples() throws {
        // Samples beyond [-1, 1] are clamped
        let samples: [Float] = [2.0, -2.0, 0.0]
        let data = WAVFile.int16WAVData(samples: samples)

        // Read sample 0 (should be Int16.max = 32767)
        let s0 = Int16(bitPattern: UInt16(data[44]) | UInt16(data[45]) << 8)
        #expect(s0 == Int16.max)

        // Read sample 1 (should be -32768)
        let s1 = Int16(bitPattern: UInt16(data[46]) | UInt16(data[47]) << 8)
        #expect(s1 == Int16.min)

        // Read sample 2 (should be 0)
        let s2 = Int16(bitPattern: UInt16(data[48]) | UInt16(data[49]) << 8)
        #expect(s2 == 0)
    }

    @Test func int16WAVDataNearPositiveOne() throws {
        let samples: [Float] = [Float(1.0).nextDown]
        let data = WAVFile.int16WAVData(samples: samples)

        // The sample just below 1.0 should map to Int16.max (32767)
        let s0 = Int16(bitPattern: UInt16(data[44]) | UInt16(data[45]) << 8)
        #expect(s0 == Int16.max)
    }

    @Test func int16WAVDataWithRange() throws {
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        let data = WAVFile.int16WAVData(samples: samples, range: 1 ..< 3)

        // Header + 2 samples * 2 bytes = 48
        #expect(data.count == 48)

        let dataSize = UInt32(data[40]) | UInt32(data[41]) << 8 | UInt32(data[42]) << 16 | UInt32(data[43]) << 24
        #expect(dataSize == 4)
    }
}
