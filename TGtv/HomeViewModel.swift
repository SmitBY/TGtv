import Foundation
import TDLibKit

struct HomeVideoItem: Hashable {
    let id: Int64
    let title: String
    let chatId: Int64
    let thumbnailPath: String?
    let minithumbnailData: Data?
    let videoFileId: Int
    let videoLocalPath: String
    let videoMimeType: String
    let isVideoReady: Bool
    let expectedSize: Int64
    let downloadedSize: Int64
    let isDownloadingCompleted: Bool
}

struct HomeSection: Hashable {
    let chatId: Int64
    let title: String
    let videos: [HomeVideoItem]
}

@MainActor
final class HomeViewModel: ObservableObject {
    let client: TDLibClient
    private let store: SelectedChatsStore
    
    @Published private(set) var sections: [HomeSection] = []
    @Published private(set) var isLoading = false
    
    init(client: TDLibClient, store: SelectedChatsStore) {
        self.client = client
        self.store = store
    }
    
    func refresh() async {
        let ids = store.load()
        guard !ids.isEmpty else {
            sections = []
            return
        }
        
        isLoading = true
        var newSections: [HomeSection] = []
        
        for chatId in ids {
            do {
                let chat = try await client.getChat(chatId: chatId)
                let videos = await fetchVideos(chatId: chatId)
                let section = HomeSection(
                    chatId: chatId,
                    title: chat.title,
                    videos: videos
                )
                newSections.append(section)
            } catch {
                print("HomeViewModel: не удалось получить чат \(chatId): \(error)")
            }
        }
        sections = newSections
        isLoading = false
    }
    
    private func fetchVideos(chatId: Int64) async -> [HomeVideoItem] {
        do {
            let result = try await client.searchChatMessages(
                chatId: chatId,
                filter: .searchMessagesFilterVideo,
                fromMessageId: 0,
                limit: 12,
                messageThreadId: 0,
                offset: 0,
                query: "",
                savedMessagesTopicId: 0,
                senderId: nil
            )
            var items: [HomeVideoItem] = []
            
            for message in result.messages {
                guard case let .messageVideo(content) = message.content else { continue }
                
                let caption = content.caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = caption.isEmpty ? "Видео" : caption
                let video = content.video
                let videoFile = video.video
                let local = videoFile.local
                
                // Пробуем получить миниатюру
                var thumbnailPath = video.thumbnail?.file.local.path
                let minithumbnailData = video.minithumbnail?.data
                
                if let thumbFile = video.thumbnail?.file {
                    let path = thumbFile.local.path
                    let fileExists = FileManager.default.fileExists(atPath: path)
                    let needsDownload = path.isEmpty || !fileExists || !thumbFile.local.isDownloadingCompleted
                    
                    if needsDownload {
                        if let downloaded = try? await downloadFile(
                            fileId: thumbFile.id,
                            priority: 8,
                            synchronous: true
                        ) {
                            thumbnailPath = downloaded.local.path
                        }
                    }
                }
                
                let contiguousSize = max(local.downloadedPrefixSize, 0)
                let expectedSize = max(Int64(videoFile.size), max(local.downloadedSize, contiguousSize))
                let isVideoReady = local.isDownloadingCompleted &&
                FileManager.default.fileExists(atPath: local.path)
                
                let item = HomeVideoItem(
                    id: message.id,
                    title: title,
                    chatId: chatId,
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
                items.append(item)
            }
            
            return items
        } catch {
            print("HomeViewModel: ошибка загрузки видео для чата \(chatId): \(error)")
            return []
        }
    }
    
    private func downloadFile(fileId: Int, priority: Int = 1, synchronous: Bool = true) async throws -> File {
        try await client.downloadFile(
            fileId: fileId,
            limit: 0,
            offset: 0,
            priority: priority,
            synchronous: synchronous
        )
    }
    
    func ensureVideoPath(for item: HomeVideoItem) async -> String? {
        let fileManager = FileManager.default
        if item.isVideoReady && fileManager.fileExists(atPath: item.videoLocalPath) {
            return item.videoLocalPath
        }
        // Не делаем полную загрузку, если файл не готов — вернём nil для потокового воспроизведения
        return nil
    }
    
    func makeStreamingCoordinator(for item: HomeVideoItem) -> VideoStreamingCoordinator {
        let info = TG.MessageMedia.VideoInfo(
            path: item.videoLocalPath,
            fileId: item.videoFileId,
            expectedSize: item.expectedSize,
            downloadedSize: item.downloadedSize,
            isDownloadingCompleted: item.isDownloadingCompleted,
            mimeType: item.videoMimeType
        )
        return VideoStreamingCoordinator(video: info, client: client)
    }
    
    func fetchLatestVideoInfo(for item: HomeVideoItem) async -> TG.MessageMedia.VideoInfo? {
        do {
            let file = try await client.getFile(fileId: item.videoFileId)
            let local = file.local
            
            // ВАЖНО: не подменяем путь на "фейковый" файл.
            // TDLib будет писать в свой local.path; если мы создадим пустой файл в другом месте,
            // moov-проверка гарантированно провалится и UI ошибочно уйдёт в full-download.
            let path = local.path
            
            let contiguousSize = max(local.downloadedPrefixSize, 0)
            let expectedSize = max(Int64(file.size), max(local.downloadedSize, contiguousSize))
            let completed = local.isDownloadingCompleted
            
            // Запускаем загрузку, если можно
            if local.canBeDownloaded && !local.isDownloadingActive && !local.isDownloadingCompleted {
                Task.detached { [client] in
                    _ = try? await client.downloadFile(
                        fileId: file.id,
                        limit: 0,
                        offset: 0,
                        priority: 32,
                        synchronous: false
                    )
                }
            }

            // Пока TDLib не выдал реальный путь, не пытаемся стримить/проверять moov.
            guard !path.isEmpty else { return nil }
            
            return TG.MessageMedia.VideoInfo(
                path: path,
                fileId: file.id,
                expectedSize: expectedSize,
                downloadedSize: contiguousSize,
                isDownloadingCompleted: completed,
                mimeType: item.videoMimeType
            )
        } catch {
            print("HomeViewModel: не удалось получить файл \(item.videoFileId): \(error)")
            return nil
        }
    }
}
