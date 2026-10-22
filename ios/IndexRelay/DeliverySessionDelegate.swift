import Foundation

struct DeliveryCompletion: Sendable {
    var tag: String; var data: Data; var status: Int?; var errorCode: Int?; var bytesSent: Int64
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
                                    errorCode: (error as NSError?)?.code, bytesSent: task.countOfBytesSent))
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) { finishedEvents() }
}
