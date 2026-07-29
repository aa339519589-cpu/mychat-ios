#!/usr/bin/env python3
from pathlib import Path
import sys

path = Path(sys.argv[1] if len(sys.argv) > 1 else "MyChatIOS/APIClient.swift")
text = path.read_text()

old = '''    func eventStream(_ accepted: ChatEnqueueResponse) -> AsyncThrowingStream<JobEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await consumeEvents(accepted, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: localizedNetworkError(error, host: baseURL.host))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
'''

new = '''    func eventStream(_ accepted: ChatEnqueueResponse) -> AsyncThrowingStream<JobEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let deadline = Date().addingTimeInterval(20 * 60)
                let completed = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
                    group.addTask {
                        do {
                            try await self.consumeEvents(accepted, continuation: continuation)
                            return true
                        } catch {
                            return false
                        }
                    }
                    group.addTask {
                        var sequence = 0
                        do {
                            return try await self.pollJobUntilTerminal(
                                accepted.jobId,
                                sequence: &sequence,
                                deadline: deadline,
                                continuation: continuation
                            )
                        } catch {
                            return false
                        }
                    }
                    while let result = await group.next() {
                        if result {
                            group.cancelAll()
                            return true
                        }
                    }
                    return false
                }
                if completed {
                    continuation.finish()
                } else if !Task.isCancelled {
                    continuation.finish(throwing: APIError.message("回复恢复失败，请重试"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
'''

if new in text:
    print("Authoritative job recovery already applied")
elif old in text:
    path.write_text(text.replace(old, new, 1))
    print("Applied authoritative job recovery")
else:
    raise SystemExit("APIClient.eventStream no longer matches the expected source")
