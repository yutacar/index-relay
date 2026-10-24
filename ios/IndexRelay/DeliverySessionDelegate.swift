import Foundation

struct DeliveryCompletion: Sendable {
    var tag: String; var data: Data; var status: Int?; var errorCode: Int?; var bytesSent: Int64; var retryAfter: TimeInterval? = nil
}
// URLSession calls this delegate on a serial operation queue; only immutable values cross to the main actor.
final class DeliverySessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var bodies: [Int: Data] = [:]
    let complete: @Sendable (DeliveryCompletion) -> Void
    let finishedEvents: @Sendable () -> Void
    init(complete: @escaping @Sendable (DeliveryCompletion) -> Void, finishedEvents: @escaping @Sendable () -> Void) {
        self.complete = complete; self.finishedEvents = finishedEvents
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if (bodies[dataTask.taskIdentifier]?.count ?? 0) + data.count <= 131_072 {
            bodies[dataTask.taskIdentifier, default: Data()].append(data)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        complete(DeliveryCompletion(tag: task.taskDescription ?? "", data: bodies.removeValue(forKey: task.taskIdentifier) ?? Data(),
                                    status: (task.response as? HTTPURLResponse)?.statusCode,
                                    errorCode: (error as NSError?)?.code, bytesSent: task.countOfBytesSent, retryAfter: Self.retryDelay((task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"))))
    }
    static func retryDelay(_ value: String?, now: Date = .now) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) { finishedEvents() }
}
