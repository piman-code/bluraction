import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import CoreFoundation
import Darwin

/// Encode already flattened pixels only. Source/generation guards and exclusive
/// destination publication belong to the exporter that calls this worker API.
/// The first CPU slice holds HDR/high-depth input explicitly; it is not a change
/// to the application's eventual HEIC/color support contract.
enum HEICCPUEncoder {
    enum EncoderError: LocalizedError {
        case invalidInput, colorReviewRequired, helperUnavailable, helperChanged
        case cancelled, timedOut, io, encodeFailed, invalidOutput, cleanupIncomplete
        var errorDescription: String? {
            switch self {
            case .invalidInput: return "HEIC CPU 입력 크기나 품질이 올바르지 않습니다."
            case .colorReviewRequired: return "이 고심도·HDR 색상은 CPU HEIC 색상 처리를 검토해야 합니다."
            case .helperUnavailable: return "앱의 검증된 HEIC CPU 인코더를 찾을 수 없습니다."
            case .helperChanged: return "HEIC CPU 인코더 바이트 또는 경로가 변경되었습니다."
            case .cancelled: return "HEIC CPU 인코딩을 취소했습니다."
            case .timedOut: return "HEIC CPU 인코딩 제한 시간을 초과했습니다."
            case .io: return "HEIC CPU 입력 또는 진단 스트림 처리에 실패했습니다."
            case .encodeFailed: return "HEIC CPU 인코딩이 완료되지 않았습니다."
            case .invalidOutput: return "HEIC CPU 출력 재열기 검증에 실패했습니다."
            case .cleanupIncomplete: return "HEIC CPU 작업 종료 또는 임시 파일 정리를 확인해야 합니다."
            }
        }
    }

    struct Helper {
        let url: URL
        let sha256: String
    }
    /// Internal deterministic test seams; production never reads an environment
    /// variable or searches PATH/global encoder locations.
    struct Hooks {
        var temporaryParent: URL? = nil
        var onAttempt: ((URL) -> Void)? = nil
        var onStarted: ((Int32) -> Void)? = nil
        var removeDirectory: ((URL) throws -> Void)? = nil
    }
    struct Pixels: Sendable {
        let width: Int
        let height: Int
        let rgba: Data // upright, unassociated sRGB RGBA8; alpha-zero RGB is zero
    }
    /// Keeps the first error and a retry owner if cleanup cannot be confirmed.
    /// No live process/descriptor/directory ownership is discarded on failure.
    final class AttemptFailure: Error, LocalizedError, @unchecked Sendable {
        let primary: Error
        let cleanup: Error?
        let diagnostics: Data
        private let retainedAttempt: Attempt?
        fileprivate init(primary: Error, cleanup: Error?, attempt: Attempt) {
            self.primary = primary; self.cleanup = cleanup
            diagnostics = attempt.state.stderrData()
            retainedAttempt = cleanup == nil ? nil : attempt
        }
        var errorDescription: String? { primary.localizedDescription }
        var cleanupNeedsRetry: Bool {
            (retainedAttempt.map { !$0.cleanupComplete } ?? false) ||
                ((primary as? ReadFailure)?.cleanupNeedsRetry ?? false)
        }
        func retryCleanup() throws {
            try (primary as? ReadFailure)?.retryCleanup()
            try retainedAttempt?.clean()
        }
    }
    /// A failed close of an owned read descriptor also retains a retry owner.
    /// FileHandle manages descriptor state; retries never reopen a pathname.
    final class ReadFailure: Error, LocalizedError, @unchecked Sendable {
        let primary: Error, cleanup: Error
        private let handle: FileHandle, lock = NSLock()
        private var closed = false
        fileprivate init(primary: Error, cleanup: Error, handle: FileHandle) {
            self.primary = primary; self.cleanup = cleanup; self.handle = handle
        }
        var errorDescription: String? { EncoderError.io.errorDescription }
        var cleanupNeedsRetry: Bool { lock.lock(); defer { lock.unlock() }; return !closed }
        func retryCleanup() throws {
            lock.lock(); defer { lock.unlock() }
            if !closed { try handle.close(); closed = true }
        }
        deinit { try? retryCleanup() }
    }

    static func encode(image: CGImage, quality: Double, cancel: (() -> Bool)? = nil) throws -> Data {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              let digest = bundle.object(forInfoDictionaryKey: "BlurActionHEICCPUEncoderSHA256") as? String
        else { throw EncoderError.helperUnavailable }
        let helper = Helper(url: bundle.bundleURL.appendingPathComponent("Contents/Helpers/HEICCPUEncoder"),
                            sha256: digest)
        let names = ["libheif.1.dylib", "libde265.0.dylib", "libkvazaar.7.dylib"]
        guard let libraries = bundle.object(forInfoDictionaryKey: "BlurActionHEICCPULibrarySHA256") as? [String: String],
              Set(libraries.keys) == Set(names) else { throw EncoderError.helperUnavailable }
        let bindings = names.map { Helper(url: bundle.bundleURL.appendingPathComponent("Contents/Frameworks/HEIC/" + $0),
                                          sha256: libraries[$0]!) }
        let baselines = try bindings.map { try helperIdentity($0, executable: false) }
        let bytes = try encode(image: image, quality: quality, helper: helper, cancel: cancel)
        guard try bindings.map({ try helperIdentity($0, executable: false) }) == baselines
        else { throw EncoderError.helperChanged }
        if cancel?() == true { throw EncoderError.cancelled }
        return bytes
    }

    /// Internal explicit helper entry point for actual owned candidate tests.
    static func encode(image: CGImage, quality: Double, helper: Helper, timeout: TimeInterval = 30,
                       cancel: (() -> Bool)? = nil, hooks: Hooks = Hooks()) throws -> Data {
        guard quality.isFinite, (0...1).contains(quality), timeout.isFinite, timeout > 0, timeout <= 120
        else { throw EncoderError.invalidInput }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try checkpoint(deadline, cancel)
        let pixels = try normalizedPixels(image)
        try checkpoint(deadline, cancel)
        let baseline = try helperIdentity(helper)
        let directory = try freshDirectory(parent: hooks.temporaryParent)
        let attempt = Attempt(directory: directory, hooks: hooks)
        do {
            hooks.onAttempt?(directory)
            try checkpoint(deadline, cancel)
            try attempt.start(helper: helper.url, pixels: pixels, quality: Int((quality * 100).rounded()))
            hooks.onStarted?(attempt.process.processIdentifier)
            while attempt.process.isRunning || !attempt.workersFinished {
                try checkpoint(deadline, cancel)
                if let failure = attempt.state.failure() { throw failure }
                Thread.sleep(forTimeInterval: 0.005)
            }
            attempt.process.waitUntilExit() // only after observed termination
            if let failure = attempt.state.failure() { throw failure }
            try checkpoint(deadline, cancel)
            guard attempt.process.terminationReason == .exit, attempt.process.terminationStatus == 0
            else { throw EncoderError.encodeFailed }
            guard try helperIdentity(helper) == baseline else { throw EncoderError.helperChanged }
            let bytes = try verifiedOutput(directory: directory, pixels: pixels,
                                           quality: Int((quality * 100).rounded()),
                                           deadline: deadline, cancel: cancel)
            try checkpoint(deadline, cancel)
            try attempt.clean()
            try checkpoint(deadline, cancel) // late cancel never returns bytes
            return bytes
        } catch {
            let primary = error
            var cleanup: Error?
            do { try attempt.clean() } catch { cleanup = error }
            throw AttemptFailure(primary: primary, cleanup: cleanup, attempt: attempt)
        }
    }

    static func normalizedPixels(_ image: CGImage) throws -> Pixels {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 24_000_000 / height else { throw EncoderError.invalidInput }
        try validateColor(image)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { throw EncoderError.colorReviewRequired }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else { throw EncoderError.invalidInput }
        // CGBitmapContext's supported RGBA8 representation is premultiplied.
        // Convert association once, not the color profile twice. Partial RGB can
        // round; alpha bytes remain unchanged and hidden transparent RGB is zero.
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[offset + 3])
            for channel in 0..<3 {
                bytes[offset + channel] = alpha == 0 ? 0 :
                    UInt8(min(255, (Int(bytes[offset + channel]) * 255 + alpha / 2) / alpha))
            }
        }
        return Pixels(width: width, height: height, rgba: Data(bytes))
    }

    /// Check the original before a render context can quantize away its depth
    /// or transfer identity. CPU support for HDR remains an explicit gate.
    static func validateColor(_ image: CGImage) throws {
        guard image.bitsPerComponent <= 8, !image.bitmapInfo.contains(.floatComponents),
              let space = image.colorSpace, space.model == .rgb || space.model == .monochrome,
              !CGColorSpaceUsesExtendedRange(space), !CGColorSpaceUsesITUR_2100TF(space)
        else { throw EncoderError.colorReviewRequired }
    }

    private static func checkpoint(_ deadline: TimeInterval, _ cancel: (() -> Bool)?) throws {
        if cancel?() == true { throw EncoderError.cancelled }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw EncoderError.timedOut }
    }
    private static func freshDirectory(parent: URL?) throws -> URL {
        let base = (parent ?? FileManager.default.temporaryDirectory).resolvingSymlinksInPath()
        guard base.isFileURL else { throw EncoderError.invalidInput }
        var template = Array(base.appendingPathComponent("bluraction-heic-cpu-XXXXXX").path.utf8CString)
        guard let path = mkdtemp(&template) else { throw EncoderError.io }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    private struct Identity: Equatable {
        let device: dev_t; let inode: ino_t; let mode: UInt32; let size: Int64
        let modifiedSeconds: Int64; let modifiedNanos: Int64
        let changedSeconds: Int64; let changedNanos: Int64
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; mode = UInt32(value.st_mode)
            size = value.st_size
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
        }
    }
    private static func helperIdentity(_ helper: Helper, executable: Bool = true) throws -> Identity {
        guard helper.url.isFileURL, helper.url.path == helper.url.standardizedFileURL.path,
              helper.sha256.count == 64, helper.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              helper.url.resolvingSymlinksInPath().path == helper.url.path,
              access(helper.url.path, executable ? X_OK : R_OK) == 0
        else { throw EncoderError.helperUnavailable }
        var info = stat()
        guard lstat(helper.url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= 64 * 1024 * 1024 else { throw EncoderError.helperUnavailable }
        let before = Identity(info)
        let data = try readRegular(helper.url, limit: 64 * 1024 * 1024)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == helper.sha256 else { throw EncoderError.helperChanged }
        guard lstat(helper.url.path, &info) == 0, Identity(info) == before else { throw EncoderError.helperChanged }
        return before
    }
    private static func readRegular(_ url: URL, limit: Int) throws -> Data {
        var data = Data()
        try readChunks(url, limit: limit) { data.append(contentsOf: $0) }
        return data
    }
    private static func digestRegular(_ url: URL, limit: Int) throws -> SHA256.Digest {
        var hasher = SHA256()
        try readChunks(url, limit: limit) { hasher.update(data: Data($0)) }
        return hasher.finalize()
    }
    private static func readChunks(_ url: URL, limit: Int, consume: (ArraySlice<UInt8>) -> Void) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw EncoderError.invalidOutput }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var before = stat()
            guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
                  before.st_size > 0, before.st_size <= limit else { throw EncoderError.invalidOutput }
            var total = 0, buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0, total + max(0, count) <= limit else { throw EncoderError.invalidOutput }
                if count == 0 { break }
                total += count; consume(buffer.prefix(count))
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0, Identity(before) == Identity(after), total == Int(before.st_size)
            else { throw EncoderError.invalidOutput }
            try handle.close()
        } catch {
            let primary = error
            do { try handle.close() }
            catch { throw ReadFailure(primary: primary, cleanup: error, handle: handle) }
            throw primary
        }
    }
    private static func verifiedOutput(directory: URL, pixels: Pixels, quality: Int,
                                       deadline: TimeInterval, cancel: (() -> Bool)?) throws -> Data {
        func exactInteger(_ value: Any?, _ expected: Int) -> Bool {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !["f", "d"].contains(String(cString: number.objCType)) else { return false }
            return number.int64Value == Int64(expected)
        }
        func exactBoolean(_ value: Any?, _ expected: Bool) -> Bool {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return number.boolValue == expected
        }
        func metric(_ value: Any?) -> Bool {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            return number.doubleValue.isFinite && (0...255).contains(number.doubleValue)
        }
        let report = try JSONSerialization.jsonObject(with: readRegular(directory.appendingPathComponent("report.json"), limit: 65536)) as? [String: Any]
        let keys: Set<String> = ["status", "encoder", "libheif", "width", "height", "quality", "encodedColorChroma", "input",
            "alphaPresent", "alphaMismatch", "nclx", "sourceMetadataCopied", "rgbMeanAbsoluteDifference", "rgbMaximumAbsoluteDifference",
            "colorParityApproved", "publishedToUserDestination", "HDRVerified", "releaseApproved"]
        let hasAlpha = stride(from: 3, to: pixels.rgba.count, by: 4).contains { pixels.rgba[$0] != 255 }
        guard let report, Set(report.keys) == keys, report["status"] as? String == "candidate-readback-complete",
              report["encoder"] as? String == "kvazaar", report["libheif"] as? String == "1.23.5",
              exactInteger(report["width"], pixels.width), exactInteger(report["height"], pixels.height),
              exactInteger(report["quality"], quality), exactInteger(report["alphaMismatch"], 0),
              let nclx = report["nclx"] as? [Any], nclx.count == 4,
              zip(nclx, [1, 13, 6, 1]).allSatisfy({ exactInteger($0.0, $0.1) }),
              report["encodedColorChroma"] as? String == "420",
              report["input"] as? String == "upright-unassociated-RGBA8-sRGB",
              exactBoolean(report["alphaPresent"], hasAlpha), exactBoolean(report["sourceMetadataCopied"], false),
              exactBoolean(report["publishedToUserDestination"], false), exactBoolean(report["colorParityApproved"], false),
              exactBoolean(report["HDRVerified"], false), exactBoolean(report["releaseApproved"], false),
              metric(report["rgbMeanAbsoluteDifference"]), metric(report["rgbMaximumAbsoluteDifference"])
        else { throw EncoderError.invalidOutput }
        let decoded = try readRegular(directory.appendingPathComponent("decoded.rgba"), limit: pixels.rgba.count)
        guard decoded.count == pixels.rgba.count else { throw EncoderError.invalidOutput }
        for offset in stride(from: 3, to: decoded.count, by: 4) {
            guard decoded[offset] == pixels.rgba[offset] else { throw EncoderError.invalidOutput }
        }
        try checkpoint(deadline, cancel)
        let bytes = try readRegular(directory.appendingPathComponent("candidate.heic"), limit: 256 * 1024 * 1024)
        let captured = SHA256.hash(data: bytes)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source).map({ $0 as String }) == "public.heic",
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width == pixels.width, image.height == pixels.height, image.bitsPerComponent == 8
        else { throw EncoderError.invalidOutput }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        guard properties[kCGImagePropertyExifDictionary as String] == nil,
              properties[kCGImagePropertyGPSDictionary as String] == nil,
              properties[kCGImagePropertyIPTCDictionary as String] == nil,
              properties[kCGImagePropertyOrientation as String] == nil || properties[kCGImagePropertyOrientation as String] as? Int == 1
        else { throw EncoderError.invalidOutput }
        let native = try normalizedPixels(image)
        guard native.width == pixels.width, native.height == pixels.height else { throw EncoderError.invalidOutput }
        for offset in stride(from: 3, to: native.rgba.count, by: 4) {
            guard native.rgba[offset] == pixels.rgba[offset] else { throw EncoderError.invalidOutput }
        }
        try checkpoint(deadline, cancel)
        // The decoder consumed immutable captured bytes. Recheck the owned file
        // after native decode using a bounded streaming hash, without another
        // full candidate buffer or a second metadata/profile conversion.
        guard try digestRegular(directory.appendingPathComponent("candidate.heic"), limit: 256 * 1024 * 1024) == captured
        else { throw EncoderError.invalidOutput }
        try checkpoint(deadline, cancel)
        return bytes
    }

    fileprivate final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false, firstError: Error?, stderr = Data()
        private var closed = Set<Int32>()
        func markClosed(_ descriptor: Int32) { lock.lock(); closed.insert(descriptor); lock.unlock() }
        func isClosed(_ descriptor: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; return closed.contains(descriptor) }
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        func shouldStop() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func fail(_ error: Error) { lock.lock(); if firstError == nil { firstError = error }; stopped = true; lock.unlock() }
        func failure() -> Error? { lock.lock(); defer { lock.unlock() }; return firstError }
        func append(_ bytes: ArraySlice<UInt8>) {
            lock.lock(); defer { lock.unlock() }
            if stderr.count + bytes.count > 65536 { if firstError == nil { firstError = EncoderError.io }; stopped = true }
            else { stderr.append(contentsOf: bytes) }
        }
        func stderrData() -> Data { lock.lock(); defer { lock.unlock() }; return stderr }
    }

    fileprivate final class Attempt: @unchecked Sendable {
        let directory: URL, hooks: Hooks
        let process = Process(), state = State()
        let input = Pipe(), diagnostic = Pipe(), workers = DispatchGroup()
        private var handles: [(Int32, FileHandle)] = []
        private let cleanupLock = NSLock()
        private let directoryDevice: dev_t, directoryInode: ino_t
        private var launched = false, removed = false
        var workersFinished: Bool { workers.wait(timeout: .now()) == .success }
        var cleanupComplete: Bool {
            cleanupLock.lock(); defer { cleanupLock.unlock() }
            return removed
        }
        init(directory: URL, hooks: Hooks) {
            self.directory = directory; self.hooks = hooks
            var info = stat(); _ = lstat(directory.path, &info)
            directoryDevice = info.st_dev; directoryInode = info.st_ino
            handles = [input.fileHandleForReading, input.fileHandleForWriting,
                       diagnostic.fileHandleForReading, diagnostic.fileHandleForWriting].map { ($0.fileDescriptor, $0) }
        }
        func start(helper: URL, pixels: Pixels, quality: Int) throws {
            let writer = input.fileHandleForWriting, reader = diagnostic.fileHandleForReading
            guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0,
                  fcntl(writer.fileDescriptor, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(reader.fileDescriptor, F_SETFL, O_NONBLOCK) == 0 else { throw EncoderError.io }
            process.executableURL = helper
            process.currentDirectoryURL = directory
            // This owned encoder needs no user search paths or codec plugins.
            // In particular DYLD_* cannot override the bundled library closure.
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": directory.path, "LANG": "C"]
            process.arguments = [String(pixels.width), String(pixels.height), String(quality), directory.path]
            // Explicit child FileHandles retain ownership here. Foundation closes
            // child-facing handles automatically when given a Pipe object.
            process.standardInput = input.fileHandleForReading
            process.standardError = diagnostic.fileHandleForWriting
            process.standardOutput = FileHandle.nullDevice
            try process.run(); launched = true
            for handle in [input.fileHandleForReading, diagnostic.fileHandleForWriting] {
                let descriptor = handle.fileDescriptor
                try handle.close(); state.markClosed(descriptor)
            }
            let state = self.state
            let writerDescriptor = writer.fileDescriptor, readerDescriptor = reader.fileDescriptor
            workers.enter()
            DispatchQueue.global(qos: .userInitiated).async { [workers] in
                defer { do { try writer.close(); state.markClosed(writerDescriptor) } catch { state.fail(error) }; workers.leave() }
                pixels.rgba.withUnsafeBytes { memory in
                    var offset = 0
                    while offset < memory.count && !state.shouldStop() {
                        var fd = pollfd(fd: writerDescriptor, events: Int16(POLLOUT), revents: 0)
                        let ready = poll(&fd, 1, 25)
                        if ready < 0 && errno == EINTR { continue }
                        if ready < 0 { state.fail(EncoderError.io); break }
                        if ready == 0 { continue }
                        let count = write(writerDescriptor, memory.baseAddress!.advanced(by: offset), min(65536, memory.count - offset))
                        if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                        if count <= 0 { if !state.shouldStop() { state.fail(EncoderError.io) }; break }
                        offset += count
                    }
                }
            }
            workers.enter()
            DispatchQueue.global(qos: .utility).async { [workers] in
                defer { do { try reader.close(); state.markClosed(readerDescriptor) } catch { state.fail(error) }; workers.leave() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while !state.shouldStop() {
                    let count = buffer.withUnsafeMutableBytes { read(readerDescriptor, $0.baseAddress, $0.count) }
                    if count > 0 { state.append(buffer.prefix(count)); continue }
                    if count == 0 { break }
                    if errno == EINTR { continue }
                    if errno != EAGAIN { state.fail(EncoderError.io); break }
                    var fd = pollfd(fd: readerDescriptor, events: Int16(POLLIN), revents: 0)
                    if poll(&fd, 1, 25) < 0 && errno != EINTR { state.fail(EncoderError.io); break }
                }
            }
        }
        func clean() throws {
            cleanupLock.lock(); defer { cleanupLock.unlock() }
            state.stop()
            if launched && process.isRunning {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.25
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.005) }
                if process.isRunning {
                    guard kill(process.processIdentifier, SIGKILL) == 0 || errno == ESRCH else { throw EncoderError.cleanupIncomplete }
                    let end = ProcessInfo.processInfo.systemUptime + 2
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.005) }
                }
                guard !process.isRunning else { throw EncoderError.cleanupIncomplete }
            }
            if launched { process.waitUntilExit() }
            guard workers.wait(timeout: .now() + 2) == .success else { throw EncoderError.cleanupIncomplete }
            var closeError: Error?
            for (descriptor, handle) in handles where !state.isClosed(descriptor) {
                do { try handle.close(); state.markClosed(descriptor) }
                catch { if closeError == nil { closeError = error } }
            }
            if let closeError { throw closeError }
            if !removed {
                var info = stat()
                if lstat(directory.path, &info) != 0 && errno == ENOENT { removed = true; return }
                guard info.st_dev == directoryDevice, info.st_ino == directoryInode,
                      (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700
                else { throw EncoderError.cleanupIncomplete }
                if let remove = hooks.removeDirectory { try remove(directory) }
                else { try FileManager.default.removeItem(at: directory) }
                removed = true
            }
        }
        deinit { try? clean() } // bounded best effort; not a success assertion
    }
}
