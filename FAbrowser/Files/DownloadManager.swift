import WebKit

final class DownloadItem {
    enum State { case downloading, paused, failed, finished }

    let id = UUID()
    var filename: String
    var sourceURL: URL?
    var state: State = .downloading
    var received: Int64 = 0
    var total: Int64 = 0
    var destination: URL?
    var error: String?

    fileprivate var task: URLSessionDownloadTask?
    fileprivate var resumeData: Data?
    fileprivate var wkDownload: WKDownload?
    fileprivate var progressObservation: NSKeyValueObservation?

    init(filename: String, sourceURL: URL?) {
        self.filename = filename
        self.sourceURL = sourceURL
    }

    var progress: Double { total > 0 ? Double(received) / Double(total) : 0 }
}

/// Handles downloads from both WKDownload (navigation responses) and URLSession (long-press "Download").
final class DownloadManager: NSObject {
    static let shared = DownloadManager()
    var backgroundCompletionHandler: (() -> Void)?

    private(set) var items: [DownloadItem] = []
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    var active: [DownloadItem] { items.filter { $0.state != .finished } }
    var activeCount: Int { items.filter { $0.state == .downloading }.count }

    private func notify() {
        NotificationCenter.default.post(name: .downloadsChanged, object: nil)
    }

    // MARK: URLSession downloads

    func download(url: URL, filename: String? = nil) {
        let item = DownloadItem(filename: filename ?? (url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent), sourceURL: url)
        var req = URLRequest(url: url)
        req.setValue(UserAgent.mobile, forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: req)
        item.task = task
        items.insert(item, at: 0)
        task.resume()
        notify()
    }

    func pause(_ item: DownloadItem) {
        if let task = item.task {
            task.cancel { data in
                item.resumeData = data
                item.state = .paused
                DispatchQueue.main.async { self.notify() }
            }
        } else if let d = item.wkDownload {
            d.cancel { data in
                item.resumeData = data
                item.state = .paused
                DispatchQueue.main.async { self.notify() }
            }
        }
    }

    func resume(_ item: DownloadItem) {
        if let data = item.resumeData, item.wkDownload == nil {
            item.task = session.downloadTask(withResumeData: data)
        } else if let url = item.sourceURL {
            item.task = session.downloadTask(with: url)
        } else {
            return
        }
        item.wkDownload = nil
        item.resumeData = nil
        item.state = .downloading
        item.task?.resume()
        notify()
    }

    func cancel(_ item: DownloadItem) {
        item.task?.cancel()
        item.wkDownload?.cancel()
        items.removeAll { $0 === item }
        notify()
    }

    func clearFinished() {
        items.removeAll { $0.state == .finished }
        notify()
    }

    func pauseAll() { items.filter { $0.state == .downloading }.forEach(pause) }
    func resumeAll() { items.filter { $0.state == .paused || $0.state == .failed }.forEach(resume) }

    private func item(for task: URLSessionTask) -> DownloadItem? { items.first { $0.task === task } }

    fileprivate func finalURL(for name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        return FileManager.default.uniqueURL(for: FileManager.default.downloadsURL.appendingPathComponent(safe.isEmpty ? "download" : safe))
    }

    // MARK: WKDownload

    func track(_ download: WKDownload) {
        let item = DownloadItem(filename: download.originalRequest?.url?.lastPathComponent ?? "download", sourceURL: download.originalRequest?.url)
        item.wkDownload = download
        item.progressObservation = download.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async {
                item.received = p.completedUnitCount
                item.total = p.totalUnitCount
                self?.notify()
            }
        }
        download.delegate = self
        items.insert(item, at: 0)
        notify()
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let item = item(for: downloadTask) else { return }
        item.received = totalBytesWritten
        item.total = totalBytesExpectedToWrite
        if let name = downloadTask.response?.suggestedFilename, item.received == bytesWritten { item.filename = name }
        notify()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let item = item(for: downloadTask) else { return }
        if let name = downloadTask.response?.suggestedFilename { item.filename = name }
        let dest = finalURL(for: item.filename)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            item.destination = dest
            item.filename = dest.lastPathComponent
            item.state = .finished
        } catch {
            item.state = .failed
            item.error = error.localizedDescription
        }
        notify()
        if item.state == .finished { Toast.show(L("Downloaded") + ": " + item.filename) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let item = item(for: task) else { return }
        if (error as NSError).code == NSURLErrorCancelled, item.state == .paused { return }
        item.state = item.resumeData != nil ? .paused : .failed
        item.resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        item.error = error.localizedDescription
        notify()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }
}

extension DownloadManager: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dest = finalURL(for: suggestedFilename)
        if let item = items.first(where: { $0.wkDownload === download }) {
            item.filename = dest.lastPathComponent
            item.destination = dest
            item.total = response.expectedContentLength
        }
        notify()
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = items.first(where: { $0.wkDownload === download }) else { return }
        item.state = .finished
        item.progressObservation = nil
        notify()
        Toast.show(L("Downloaded") + ": " + item.filename)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = items.first(where: { $0.wkDownload === download }) else { return }
        if item.state == .paused { return }
        item.state = .failed
        item.error = error.localizedDescription
        notify()
    }
}
