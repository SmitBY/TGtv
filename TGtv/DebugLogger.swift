import Foundation
import Combine

final class DebugLogger: ObservableObject {
    static let shared = DebugLogger()
    
    @Published private(set) var logs: String = ""
    
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()
    
    private init() {}
    
    func log(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let fullMessage = "[\(timestamp)] \(message)\n"
        
        print(message) // Дублируем в консоль
        
        DispatchQueue.main.async {
            self.logs.append(fullMessage)
            // Ограничиваем размер лога, чтобы не перегружать память
            if self.logs.count > 50000 {
                let index = self.logs.index(self.logs.startIndex, offsetBy: 10000)
                self.logs = String(self.logs[index...])
            }
        }
    }
}

