import Foundation
import AVFoundation
import TDLibKit

final class VideoStreamingCoordinator {
    private var currentPath: String
    private var expectedSize: Int64
    private var downloadedSize: Int64
    private var isCompleted: Bool
    private let mimeType: String
    private let fileId: Int
    private let client: TDLibClient
    private let loader: ProgressiveFileResourceLoader
    private var downloadTask: Task<Void, Never>?
    private weak var asset: AVURLAsset?
    
    init(video: TG.MessageMedia.VideoInfo, client: TDLibClient) {
        self.currentPath = video.path
        self.expectedSize = video.expectedSize
        self.downloadedSize = video.downloadedSize
        self.isCompleted = video.isDownloadingCompleted
        self.mimeType = video.mimeType
        self.fileId = video.fileId
        self.client = client
        let fileURL = URL(fileURLWithPath: video.path)
        self.loader = ProgressiveFileResourceLoader(
            fileURL: fileURL,
            mimeType: video.mimeType,
            expectedSize: video.expectedSize,
            initialDownloadedSize: video.downloadedSize,
            isCompleted: video.isDownloadingCompleted
        )
    }
    
    func matches(info: TG.MessageMedia.VideoInfo) -> Bool {
        info.fileId == fileId
    }
    
    func startDownloadIfNeeded() {
        guard downloadTask == nil, !isCompleted else { return }
        downloadTask = Task { [client, fileId = fileId] in
            do {
                _ = try await client.downloadFile(
                    fileId: fileId,
                    limit: 0,
                    offset: 0,
                    priority: 32,
                    synchronous: false
                )
            } catch { }
        }
    }
    
    func makePlayerItem() -> AVPlayerItem? {
        ensureLocalFileExists(path: currentPath)
        
        loader.updatePath(
            path: currentPath,
            downloadedSize: downloadedSize,
            isCompleted: isCompleted,
            expectedSize: expectedSize
        )
        
        let asset = AVURLAsset(url: loader.streamURL, options: assetOptions(for: mimeType))
        self.asset = asset
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let playerItem = AVPlayerItem(asset: asset)
        return playerItem
    }
    
    func handleFileUpdate(_ file: TDLibKit.File) {
        guard file.id == fileId else { return }
        let local = file.local
        let contiguousSize = max(local.downloadedPrefixSize, 0)
        let newExpectedSize = max(Int64(file.size), max(local.downloadedSize, contiguousSize))
        
        currentPath = local.path
        expectedSize = newExpectedSize
        downloadedSize = contiguousSize
        isCompleted = local.isDownloadingCompleted
        
        loader.updatePath(
            path: currentPath,
            downloadedSize: contiguousSize,
            isCompleted: local.isDownloadingCompleted,
            expectedSize: newExpectedSize
        )
    }
    
    func stop() {
        downloadTask?.cancel()
        downloadTask = nil
        loader.invalidate()
        asset = nil
    }
    
    private func assetOptions(for mimeType: String) -> [String: Any] {
        var options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]
        if !mimeType.isEmpty {
            options["AVURLAssetOutOfBandMIMETypeKey"] = mimeType
        }
        return options
    }

    private func ensureLocalFileExists(path: String) {
        guard !path.isEmpty else { return }
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) {
            _ = fm.createFile(atPath: path, contents: nil)
        }
    }
}

final class ProgressiveFileResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "com.tgtv.videostream.loader")
    let streamURL: URL
    
    private var fileURL: URL
    private let mimeType: String
    private var expectedSize: Int64
    private var downloadedSize: Int64
    private var isCompleted: Bool
    private var pendingRequests: [AVAssetResourceLoadingRequest] = []
    private var isInvalidated = false
    private let fileReadQueue = DispatchQueue(label: "com.tgtv.videostream.reader", qos: .userInitiated)
    private var hasProvidedContentInformation = false
    
    init(fileURL: URL, mimeType: String, expectedSize: Int64, initialDownloadedSize: Int64, isCompleted: Bool) {
        self.fileURL = fileURL
        self.mimeType = mimeType
        self.expectedSize = expectedSize
        self.downloadedSize = initialDownloadedSize
        self.isCompleted = isCompleted
        self.streamURL = URL(string: "tgstream://\(UUID().uuidString)")!
    }
    
    func updatePath(path: String, downloadedSize: Int64, isCompleted: Bool, expectedSize: Int64? = nil) {
        queue.async {
            self.fileURL = URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: path) {
                _ = FileManager.default.createFile(atPath: path, contents: nil)
            }
            // ВАЖНО: нельзя ориентироваться на размер файла на диске при частичной загрузке.
            // TDLib может создавать "дырявый" (sparse) файл и/или выставлять полный размер,
            // хотя реально доступен только скачанный префикс (downloadedPrefixSize).
            self.downloadedSize = max(downloadedSize, 0)
            self.isCompleted = isCompleted
            if let expectedSize {
                self.expectedSize = expectedSize
            }
            self.hasProvidedContentInformation = false
            self.processPendingRequests()
        }
    }
    
    func update(downloadedSize: Int64, isCompleted: Bool, expectedSize: Int64? = nil) {
        queue.async {
            guard !self.isInvalidated else { return }
            self.downloadedSize = downloadedSize
            self.isCompleted = isCompleted
            if let expectedSize, expectedSize > self.expectedSize {
                self.expectedSize = expectedSize
            } else if downloadedSize > self.expectedSize {
                self.expectedSize = downloadedSize
            }
            self.processPendingRequests()
        }
    }
    
    func invalidate() {
        queue.async {
            self.isInvalidated = true
            self.pendingRequests.forEach { $0.finishLoading() }
            self.pendingRequests.removeAll()
        }
    }
    
    // MARK: AVAssetResourceLoaderDelegate
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        queue.async {
            guard !self.isInvalidated else {
                loadingRequest.finishLoading()
                return
            }
            self.pendingRequests.append(loadingRequest)
            _ = self.respond(to: loadingRequest)
        }
        return true
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        queue.async {
            self.pendingRequests.removeAll { $0 == loadingRequest }
        }
    }
    
    // MARK: Internal helpers
    
    private func processPendingRequests() {
        pendingRequests = pendingRequests.filter { !respond(to: $0) }
    }
    
    @discardableResult
    private func respond(to loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        provideContentInformationIfNeeded(for: loadingRequest)
        
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        
        let requestedOffset = dataRequest.requestedOffset
        let requestedLength = Int64(dataRequest.requestedLength)
        var currentOffset = dataRequest.currentOffset
        if currentOffset < requestedOffset {
            currentOffset = requestedOffset
        }
        
        // При незавершённой загрузке считаем доступными только байты в непрерывном префиксе.
        // Иначе AVPlayer может попросить диапазоны, которые ещё не скачаны (или попадают в "дырки"),
        // а мы случайно отдадим нули/мусор → ошибки декодирования и вечный .unknown.
        let fileSize: UInt64? = isCompleted ? getFileSize() : nil
        let endOffset = requestedOffset + requestedLength
        let availableBytes: Int64 = {
            if isCompleted {
                let size = fileSize.map(Int64.init) ?? expectedSize
                return max(size, 0)
            }
            // Ограничиваемся contiguous префиксом
            if expectedSize > 0 {
                return min(max(downloadedSize, 0), expectedSize)
            }
            return max(downloadedSize, 0)
        }()
        
        if availableBytes <= currentOffset {
            if !isCompleted {
                return false
            }
            finish(loadingRequest)
            return true
        }
        
        let bytesToRead = min(endOffset - currentOffset, availableBytes - currentOffset)
        guard bytesToRead > 0 else {
            if isCompleted {
                finish(loadingRequest)
                return true
            }
            return false
        }
        
        guard let data = readData(offset: currentOffset, length: Int(bytesToRead)), !data.isEmpty else {
            if isCompleted {
                finish(loadingRequest)
                return true
            }
            return false
        }
        
        dataRequest.respond(with: data)
        let fullySatisfied = (currentOffset + Int64(data.count)) >= endOffset
        if fullySatisfied {
            finish(loadingRequest)
            return true
        }
        
        return false
    }
    
    private func getFileSize() -> UInt64? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? UInt64 {
            return size
        }
        return nil
    }
    
    private func finish(_ loadingRequest: AVAssetResourceLoadingRequest) {
        provideContentInformationIfNeeded(for: loadingRequest)
        loadingRequest.finishLoading()
    }
    
    private func provideContentInformationIfNeeded(for loadingRequest: AVAssetResourceLoadingRequest) {
        guard !hasProvidedContentInformation,
              let infoRequest = loadingRequest.contentInformationRequest else { return }
        infoRequest.contentType = contentType(for: mimeType)
        // contentLength — полный размер ассета (если известен).
        // Не используем размер файла на диске как источник истины при частичной загрузке.
        let length = expectedSize > 0 ? expectedSize : max(downloadedSize, 0)
        infoRequest.contentLength = length
        infoRequest.isByteRangeAccessSupported = true
        hasProvidedContentInformation = true
    }
    
    private func readData(offset: Int64, length: Int) -> Data? {
        fileReadQueue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return nil
            }
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: fileURL)
            } catch {
                return nil
            }
            defer { try? handle.close() }
            
            do {
                try handle.seek(toOffset: UInt64(offset))
                return handle.readData(ofLength: length)
            } catch {
                return nil
            }
        }
    }
    
    private func contentType(for mimeType: String) -> String {
        let lower = mimeType.lowercased()
        if lower.contains("mp4") {
            return AVFileType.mp4.rawValue
        } else if lower.contains("quicktime") || lower.contains("mov") {
            return AVFileType.mov.rawValue
        } else if lower.contains("m4v") {
            return AVFileType.m4v.rawValue
        }
        return AVFileType.mp4.rawValue
    }
}

