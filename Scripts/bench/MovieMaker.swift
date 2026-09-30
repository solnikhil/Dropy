// Writes a disposable test movie for media-app device checks: H.264, 640×360, 30 fps,
// a moving bar and a frame counter, so every frame differs from the last.
//
//   swiftc -O -o MovieMaker Scripts/bench/MovieMaker.swift && ./MovieMaker out.mov [seconds]
import AVFoundation
import CoreGraphics
import CoreText
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write(Data("usage: MovieMaker <out.mov> [seconds]\n".utf8)); exit(2) }
let url = URL(fileURLWithPath: args[1])
let seconds = args.count > 2 ? Int(args[2]) ?? 20 : 20
let width = 640, height = 360, fps: Int32 = 30
try? FileManager.default.removeItem(at: url)
let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
let font = CTFontCreateWithName("Menlo-Bold" as CFString, 48, nil)
for frame in 0..<(seconds * Int(fps)) {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let buffer else { fatalError("no pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: (frame * 8) % width, y: 80, width: 60, height: 200))
    let text = NSAttributedString(string: "Dropy media \(frame)", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.textPosition = CGPoint(x: 24, y: 24)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
    CVPixelBufferUnlockBaseAddress(buffer, [])
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fatalError("writing failed: \(String(describing: writer.error))") }
print(url.path)
