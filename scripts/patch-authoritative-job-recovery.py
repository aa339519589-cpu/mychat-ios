#!/usr/bin/env python3
from pathlib import Path
import sys

path = Path(sys.argv[1] if len(sys.argv) > 1 else "MyChatIOS/RootView.swift")
text = path.read_text()

old = '''                let stream = await api.eventStream(accepted)
                for try await event in stream {
                    if event.kind == "text.delta", let delta = event.payload["text"]?.string {
                        append(delta, to: assistantID)
                    }
                    if event.kind == "thinking.delta",
                       let delta = event.payload["thinking"]?.string {
                        appendThinking(delta, to: assistantID)
                    }
                    if event.kind == "job.retry_scheduled" {
                        resetAssistant(assistantID)
                    }
                    if event.kind == "job.warning", let message = event.payload["message"]?.string {
                        error = message
                    }
                    if event.kind == "job.terminal",
                       let status = event.payload["status"]?.string,
                       status != "completed" {
                        throw APIError.message(event.payload["error"]?.message ?? "生成未完成")
                    }
                    if event.kind == "job.terminal",
                       let result = event.payload["result"]?.object {
                        applyTerminal(result, to: assistantID)
                    }
                }
                try await refresh(conversationID: conversation.id)
'''

new = '''                _ = accepted
                let deadline = Date().addingTimeInterval(90)
                while !Task.isCancelled && Date() < deadline {
                    let authoritative = try await api.messages(conversationID: conversation.id)
                    if let reply = authoritative.first(where: { $0.id == assistantID }),
                       !reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        messages = authoritative
                        conversations = try await api.conversations()
                        selectedConversation = conversations.first(where: { $0.id == conversation.id })
                            ?? selectedConversation
                        failedMessageID = nil
                        retryContext = nil
                        return
                    }
                    try await Task.sleep(nanoseconds: 750_000_000)
                }
                throw APIError.message("回复已提交，但最终内容未同步，请重试")
'''

if new in text:
    print("Persisted assistant recovery already applied")
elif old in text:
    path.write_text(text.replace(old, new, 1))
    print("Applied persisted assistant recovery")
else:
    raise SystemExit("ChatStore.send no longer matches the expected source")
