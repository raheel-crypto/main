import { useState, useRef, useEffect } from "react";
import { cn } from "../lib/utils";
import { api, ArchitectMessage } from "../lib/api";

interface Message {
  role: "user" | "assistant";
  content: string;
  toolCalls?: { name: string; input: any; result: string }[];
}

const SUGGESTIONS = [
  "Analyze my Account object and suggest improvements to the data model",
  "Review my permission sets and recommend a least-privilege security redesign",
  "Find all record-triggered flows and check if any can be consolidated",
  "Design a permission set strategy for a new Sales Operations team",
  "Review validation rules on Opportunity and suggest improvements",
  "Help me create a new custom object for tracking customer feedback",
];

export function ArchitectPage() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [showTools, setShowTools] = useState<number | null>(null);
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  const send = async (text?: string) => {
    const messageText = text || input.trim();
    if (!messageText || isLoading) return;

    const userMessage: Message = { role: "user", content: messageText };
    const newMessages = [...messages, userMessage];
    setMessages(newMessages);
    setInput("");
    setIsLoading(true);

    try {
      const chatHistory = newMessages.map((m) => ({
        role: m.role,
        content: m.content,
      }));
      const response = await api.architectChat(chatHistory);
      setMessages([...newMessages, response as Message]);
    } catch (err: any) {
      setMessages([
        ...newMessages,
        { role: "assistant", content: `Error: ${err.message}` },
      ]);
    } finally {
      setIsLoading(false);
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      send();
    }
  };

  return (
    <div className="flex h-[calc(100vh-7rem)] flex-col">
      <div className="mb-4">
        <h1 className="text-2xl font-bold text-foreground">Architect</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          AI-powered assistant that can analyze, redesign, and deploy changes to your Salesforce org
        </p>
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-auto rounded-lg border border-border bg-card">
        {messages.length === 0 ? (
          <div className="flex h-full flex-col items-center justify-center p-8">
            <div className="mb-6 flex h-16 w-16 items-center justify-center rounded-2xl bg-primary/10">
              <svg className="h-8 w-8 text-primary" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                <path d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z" />
              </svg>
            </div>
            <h2 className="text-lg font-semibold text-foreground">
              What would you like to redesign?
            </h2>
            <p className="mt-1 text-center text-sm text-muted-foreground max-w-md">
              I can analyze your org, redesign flows and permissions, create fields, and deploy changes directly.
            </p>
            <div className="mt-6 grid grid-cols-2 gap-2 max-w-2xl">
              {SUGGESTIONS.map((s) => (
                <button
                  key={s}
                  onClick={() => send(s)}
                  className="rounded-lg border border-border px-3 py-2 text-left text-xs text-muted-foreground transition-colors hover:border-primary/50 hover:bg-accent/50 hover:text-foreground"
                >
                  {s}
                </button>
              ))}
            </div>
          </div>
        ) : (
          <div className="space-y-4 p-4">
            {messages.map((msg, i) => (
              <div key={i}>
                <div
                  className={cn(
                    "flex gap-3",
                    msg.role === "user" ? "justify-end" : "justify-start"
                  )}
                >
                  {msg.role === "assistant" && (
                    <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-primary/10">
                      <svg className="h-4 w-4 text-primary" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path d="M13 10V3L4 14h7v7l9-11h-7z" />
                      </svg>
                    </div>
                  )}
                  <div
                    className={cn(
                      "max-w-[75%] rounded-lg px-4 py-3",
                      msg.role === "user"
                        ? "bg-primary text-primary-foreground"
                        : "bg-muted text-foreground"
                    )}
                  >
                    <div className="whitespace-pre-wrap text-sm">{msg.content}</div>
                  </div>
                </div>

                {/* Tool calls */}
                {msg.toolCalls && msg.toolCalls.length > 0 && (
                  <div className="ml-11 mt-2">
                    <button
                      onClick={() => setShowTools(showTools === i ? null : i)}
                      className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
                    >
                      <svg
                        className={cn(
                          "h-3 w-3 transition-transform",
                          showTools === i && "rotate-90"
                        )}
                        fill="none"
                        viewBox="0 0 24 24"
                        stroke="currentColor"
                        strokeWidth={2}
                      >
                        <polyline points="9,18 15,12 9,6" />
                      </svg>
                      {msg.toolCalls.length} tool call{msg.toolCalls.length > 1 ? "s" : ""} executed
                    </button>
                    {showTools === i && (
                      <div className="mt-2 space-y-2">
                        {msg.toolCalls.map((tc, j) => (
                          <div
                            key={j}
                            className="rounded border border-border bg-background p-3"
                          >
                            <div className="flex items-center gap-2">
                              <span className="rounded bg-cyan-500/10 px-1.5 py-0.5 text-xs font-mono text-cyan-400">
                                {tc.name}
                              </span>
                            </div>
                            <pre className="mt-2 max-h-32 overflow-auto text-xs text-muted-foreground">
                              {JSON.stringify(tc.input, null, 2)}
                            </pre>
                            <pre className="mt-1 max-h-32 overflow-auto rounded bg-muted p-2 text-xs text-foreground">
                              {tc.result.substring(0, 500)}
                              {tc.result.length > 500 && "..."}
                            </pre>
                          </div>
                        ))}
                      </div>
                    )}
                  </div>
                )}
              </div>
            ))}

            {isLoading && (
              <div className="flex gap-3">
                <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-primary/10">
                  <div className="h-4 w-4 animate-spin rounded-full border-2 border-primary border-t-transparent" />
                </div>
                <div className="rounded-lg bg-muted px-4 py-3">
                  <div className="text-sm text-muted-foreground">
                    Thinking and querying your org...
                  </div>
                </div>
              </div>
            )}

            <div ref={messagesEndRef} />
          </div>
        )}
      </div>

      {/* Input */}
      <div className="mt-3 flex gap-2">
        <textarea
          ref={inputRef}
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder="Ask the architect to analyze, redesign, or deploy changes..."
          rows={2}
          className="flex-1 resize-none rounded-lg border border-input bg-background px-4 py-3 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
          disabled={isLoading}
        />
        <button
          onClick={() => send()}
          disabled={!input.trim() || isLoading}
          className="self-end rounded-lg bg-primary px-4 py-3 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90 disabled:opacity-50"
        >
          <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <line x1="22" y1="2" x2="11" y2="13" />
            <polygon points="22,2 15,22 11,13 2,9" />
          </svg>
        </button>
      </div>
    </div>
  );
}
