import Accelerate
import CoreML
import Foundation

/// Tách giọng bằng UVR MDX-Net (Core ML fp16, MIT, github.com/TRvlvr/model_repo qua huggingface.co/gyoom/UVR-MDX-CoreML).
/// Model chỉ là lõi học trên phổ; STFT / iSTFT làm ở đây theo đúng hợp đồng của bản chuyển đổi:
/// Hann tuần hoàn, center=True (đệm phản xạ n_fft/2), STFT không chuẩn hoá, bỏ bin Nyquist (dimF = n_fft/2),
/// vào / ra [1, 4, dimF, 256] = [L_re, L_im, R_re, R_im] theo hàng, nhạc 44,1 kHz. Ra = phổ giọng.
final class MDXVocals: @unchecked Sendable {
    static let hop = 1024, dimT = 256
    /// Số mẫu mỗi lần chạy (44,1 kHz): hop × (dimT − 1) ≈ 5,92 s.
    static let frames = hop * (dimT - 1)

    let nFFT: Int, dimF: Int
    private let model: MLModel
    private let forward: OpaquePointer, inverse: OpaquePointer
    private let window: [Float]

    /// `nFFT` 4096 cho UVR_MDXNET_9482, 6144 cho Voc_FT.
    init?(model: MLModel, nFFT: Int) {
        guard let f = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nFFT), .FORWARD),
              let i = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nFFT), .INVERSE) else { return nil }
        self.model = model
        self.nFFT = nFFT
        dimF = nFFT / 2
        forward = f; inverse = i
        window = (0..<nFFT).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nFFT))) }
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    /// Phổ kiểu torch.stft (center, reflect, không chuẩn hoá) của `frames` mẫu, bỏ Nyquist:
    /// ghi vào `re` / `im` theo [bin * dimT + frame].
    func stft(_ x: [Float], re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        let n = nFFT, half = n / 2, L = x.count
        var even = [Float](repeating: 0, count: half), odd = even, outR = even, outI = even
        for t in 0..<Self.dimT {
            let start = t * Self.hop - half
            for m in 0..<n {
                var j = start + m
                if j < 0 { j = -j } else if j >= L { j = 2 * (L - 1) - j }   // đệm phản xạ
                let v = x[min(max(j, 0), L - 1)] * window[m]
                if m & 1 == 0 { even[m >> 1] = v } else { odd[m >> 1] = v }
            }
            vDSP_DFT_Execute(forward, even, odd, &outR, &outI)
            // zrop nhân 2; ô 0 chứa DC (thực) và Nyquist (ảo) → bỏ Nyquist.
            for k in 0..<dimF {
                re[k * Self.dimT + t] = outR[k] * 0.5
                im[k * Self.dimT + t] = k == 0 ? 0 : outI[k] * 0.5
            }
        }
    }

    /// Ngược lại `stft` (torch.istft center=True): chồng cộng có chia tổng cửa sổ², trả `length` mẫu.
    func istft(re: UnsafePointer<Float>, im: UnsafePointer<Float>, length: Int) -> [Float] {
        let n = nFFT, half = n / 2
        let total = (Self.dimT - 1) * Self.hop + n
        var y = [Float](repeating: 0, count: total), wsum = y
        var inR = [Float](repeating: 0, count: half), inI = inR, outE = inR, outO = inR
        for t in 0..<Self.dimT {
            for k in 0..<dimF {
                inR[k] = re[k * Self.dimT + t]
                inI[k] = k == 0 ? 0 : im[k * Self.dimT + t]
            }
            vDSP_DFT_Execute(inverse, inR, inI, &outE, &outO)
            let start = t * Self.hop
            for m in 0..<n {
                let v = (m & 1 == 0 ? outE[m >> 1] : outO[m >> 1]) / Float(n)   // zrop ngược nhân n
                y[start + m] += v * window[m]
                wsum[start + m] += window[m] * window[m]
            }
        }
        return (0..<length).map { i in
            let w = wsum[i + half]
            return w > 1e-8 ? y[i + half] / w : 0
        }
    }

    /// Giọng của đúng `frames` mẫu stereo 44,1 kHz.
    func vocals(_ l: [Float], _ r: [Float]) -> (l: [Float], r: [Float])? {
        let plane = dimF * Self.dimT, count = 4 * plane
        var spec = [Float](repeating: 0, count: count)
        spec.withUnsafeMutableBufferPointer { s in
            let b = s.baseAddress!
            stft(l, re: b, im: b + plane)
            stft(r, re: b + 2 * plane, im: b + 3 * plane)
        }
        guard let input = try? MLMultiArray(shape: [1, 4, NSNumber(value: dimF), NSNumber(value: Self.dimT)],
                                            dataType: .float16) else { return nil }
        Self.toHalf(spec, input.dataPointer)
        guard let fp = try? MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)]),
              let out = try? model.prediction(from: fp).featureValue(for: "output")?.multiArrayValue,
              out.count == count else { return nil }
        if out.dataType == .float16 {
            Self.fromHalf(out.dataPointer, into: &spec)
        } else if out.dataType == .float32 {
            spec.withUnsafeMutableBufferPointer {
                $0.baseAddress!.update(from: out.dataPointer.assumingMemoryBound(to: Float.self), count: count)
            }
        } else { return nil }
        return spec.withUnsafeBufferPointer { s in
            let b = s.baseAddress!
            return (istft(re: b, im: b + plane, length: l.count), istft(re: b + 2 * plane, im: b + 3 * plane, length: r.count))
        }
    }

    // fp16 qua vImage: chạy được cả trên Intel (không có kiểu Float16).
    static func toHalf(_ src: [Float], _ dst: UnsafeMutableRawPointer) {
        src.withUnsafeBufferPointer { s in
            var a = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s.baseAddress!), height: 1,
                                  width: vImagePixelCount(src.count), rowBytes: src.count * 4)
            var b = vImage_Buffer(data: dst, height: 1, width: vImagePixelCount(src.count), rowBytes: src.count * 2)
            vImageConvert_PlanarFtoPlanar16F(&a, &b, 0)
        }
    }

    static func fromHalf(_ src: UnsafeMutableRawPointer, into dst: inout [Float]) {
        let n = dst.count
        dst.withUnsafeMutableBufferPointer { d in
            var a = vImage_Buffer(data: src, height: 1, width: vImagePixelCount(n), rowBytes: n * 2)
            var b = vImage_Buffer(data: d.baseAddress!, height: 1, width: vImagePixelCount(n), rowBytes: n * 4)
            vImageConvert_Planar16FtoPlanarF(&a, &b, 0)
        }
    }
}
