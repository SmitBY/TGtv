import Foundation
import TDLibKit

@MainActor
final class SearchViewModel: ObservableObject {
    let client: TDLibClient

    @Published private(set) var items: [HomeVideoItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: Swift.Error?

    private var searchTask: Task<Void, Never>?
    private var currentQuery: String = ""

    init(client: TDLibClient) {
        self.client = client
    }

    func updateQuery(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != currentQuery else { return }
        currentQuery = query

        searchTask?.cancel()
        searchTask = nil

        if query.isEmpty {
            items = []
            isLoading = false
            error = nil
            return
        }

        isLoading = true
        error = nil

        let debounceNanos: UInt64 = 300_000_000
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: debounceNanos)
            } catch {
                return
            }
            guard let self else { return }
            if Task.isCancelled { return }
            await self.performSearch(query: query)
        }
    }

    private func performSearch(query: String) async {
        do {
            let result = try await client.searchMessages(
                chatList: nil,
                chatTypeFilter: nil,
                filter: .searchMessagesFilterVideo,
                limit: 50,
                maxDate: nil,
                minDate: nil,
                offset: nil,
                query: query
            )

            var newItems: [HomeVideoItem] = []
            newItems.reserveCapacity(result.messages.count)

            for message in result.messages {
                guard case let .messageVideo(content) = message.content else { continue }

                let caption = content.caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = caption.isEmpty ? NSLocalizedString("video.defaultTitle", comment: "") : caption

                let video = content.video
                let videoFile = video.video
                let local = videoFile.local

                // Миниатюры
                var thumbnailPath = video.thumbnail?.file.local.path
                let minithumbnailData = video.minithumbnail?.data

                if let thumbFile = video.thumbnail?.file {
                    let path = thumbFile.local.path
                    let fileExists = FileManager.default.fileExists(atPath: path)
                    let needsDownload = path.isEmpty || !fileExists || !thumbFile.local.isDownloadingCompleted

                    if needsDownload {
                        if let downloaded = try? await downloadFile(fileId: thumbFile.id, priority: 8, synchronous: true) {
                            thumbnailPath = downloaded.local.path
                        }
                    }
                }

                let contiguousSize = max(local.downloadedPrefixSize, 0)
                let expectedSize = max(Int64(videoFile.size), max(local.downloadedSize, contiguousSize))
                let isVideoReady = local.isDownloadingCompleted && FileManager.default.fileExists(atPath: local.path)

                let item = HomeVideoItem(
                    id: message.id,
                    title: title,
                    chatId: message.chatId,
                    thumbnailPath: thumbnailPath,
                    minithumbnailData: minithumbnailData,
                    videoFileId: videoFile.id,
                    videoLocalPath: local.path,
                    videoMimeType: video.mimeType.isEmpty ? "video/mp4" : video.mimeType,
                    isVideoReady: isVideoReady,
                    expectedSize: expectedSize,
                    downloadedSize: contiguousSize,
                    isDownloadingCompleted: local.isDownloadingCompleted
                )
                newItems.append(item)
            }

            guard currentQuery == query else { return }
            self.items = newItems
            self.isLoading = false
            self.error = nil
        } catch {
            guard currentQuery == query else { return }
            self.items = []
            self.isLoading = false
            self.error = error
        }
    }

    private func downloadFile(fileId: Int, priority: Int = 1, synchronous: Bool = true) async throws -> TDLibKit.File {
        try await client.downloadFile(
            fileId: fileId,
            limit: 0,
            offset: 0,
            priority: priority,
            synchronous: synchronous
        )
    }
}

