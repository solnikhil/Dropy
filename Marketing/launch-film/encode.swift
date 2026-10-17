// Encodes a folder of numbered JPEG/PNG frames into an H.264 MP4 with AVFoundation,
// with an optional soundtrack (any audio file AVFoundation reads; trimmed to the picture).
//   swiftc -O -swift-version 5 encode.swift -o encode && ./encode <framesDir> <out.mp4> [fps=60] [bitsPerSecond=45000000] [audio]
import AVFoundation
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: encode <framesDir> <out.mp4> [fps]\n".data(using: .utf8)!)
    exit(1)
}
let dir = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
let fps = Int32(args.count > 3 ? Int(args[3]) ?? 60 : 60)
let bitrate = args.count > 4 ? Int(args[4]) ?? 45_000_000 : 45_000_000
let audioURL = args.count > 5 ? URL(fileURLWithPath: args[5]) : nil
let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    .filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }
    .sorted()
guard let first = files.first,
      let src0 = CGImageSourceCreateWithURL(dir.appendingPathComponent(first) as CFURL, nil),
      let img0 = CGImageSourceCreateImageAtIndex(src0, 0, nil) else {
    FileHandle.standardError.write("no frames in \(dir.path)\n".data(using: .utf8)!)
    exit(1)
}
let width = img0.width, height = img0.height

try? FileManager.default.removeItem(at: out)
let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
let settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ],
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitrate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
        AVVideoExpectedSourceFrameRateKey: Int(fps),
    ],
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])
writer.add(input)

// The soundtrack, decoded to PCM and re-encoded as AAC.
var audioInput: AVAssetWriterInput?
var audioOutput: AVAssetReaderTrackOutput?
var reader: AVAssetReader?
if let audioURL {
    let asset = AVURLAsset(url: audioURL)
    guard let track = asset.tracks(withMediaType: .audio).first else { fatalError("no audio in \(audioURL.path)") }
    let r = try AVAssetReader(asset: asset)
    let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
    ])
    r.add(o)
    let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
    ])
    writer.add(a)
    guard r.startReading() else { fatalError("cannot read \(audioURL.path)") }
    reader = r; audioOutput = o; audioInput = a
}

guard writer.startWriting() else { fatalError("\(writer.error.map { "\($0)" } ?? "cannot start")") }
writer.startSession(atSourceTime: .zero)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let group = DispatchGroup()

group.enter()
var frame = 0
input.requestMediaDataWhenReady(on: DispatchQueue(label: "video")) {
    while input.isReadyForMoreMediaData {
        if frame >= files.count { input.markAsFinished(); group.leave(); return }
        autoreleasepool {
            let name = files[frame]
            guard let src = CGImageSourceCreateWithURL(dir.appendingPathComponent(name) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("unreadable \(name)") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let pb = buffer else { fatalError("no pixel buffer") }
            CVPixelBufferLockBaseAddress(pb, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(pb, [])
            if !adaptor.append(pb, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)) {
                fatalError("append failed at \(frame): \(writer.error.map { "\($0)" } ?? "")")
            }
        }
        frame += 1
    }
}

let videoEnd = CMTime(value: Int64(files.count), timescale: fps)
if let audioInput, let audioOutput {
    group.enter()
    audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audio")) {
        while audioInput.isReadyForMoreMediaData {
            guard let sample = audioOutput.copyNextSampleBuffer(),
                  CMSampleBufferGetPresentationTimeStamp(sample) < videoEnd else {
                audioInput.markAsFinished(); group.leave(); return
            }
            audioInput.append(sample)
        }
    }
}

group.wait()
writer.endSession(atSourceTime: videoEnd)
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
if writer.status != .completed { fatalError("\(writer.error.map { "\($0)" } ?? "failed")") }
_ = reader
print("wrote \(files.count) frames (\(width)×\(height) @ \(fps) fps)\(audioURL == nil ? "" : " with sound") to \(out.path)")
