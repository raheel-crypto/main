import { useState, useEffect } from "react";
import { cn } from "../lib/utils";
import { api, SFMcpTool } from "../lib/api";

interface ToolRunState {
  args: string;
  result: string | null;
  isRunning: boolean;
  error: string | null;
}

export function SFMcpPage() {
  const [tools, setTools] = useState<SFMcpTool[]>([]);
  const [connected, setConnected] = useState(false);
  const [connectionError, setConnectionError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [expanded, setExpanded] = useState<string | null>(null);
  const [runStates, setRunStates] = useState<Record<string, ToolRunState>>({});

  useEffect(() => {
    api
      .getSFMcpTools()
      .then((res) => {
        setTools(res.tools);
        setConnected(res.connected);
        setConnectionError(res.error || null);
      })
      .catch((err) => {
        setConnected(false);
        setConnectionError(err.message);
      })
      .finally(() => setIsLoading(false));
  }, []);

  const toggleExpand = (name: string) => {
    setExpanded(expanded === name ? null : name);
    if (!runStates[name]) {
      setRunStates((prev) => ({
        ...prev,
        [name]: { args: "{}", result: null, isRunning: false, error: null },
      }));
    }
  };

  const runTool = async (tool: SFMcpTool) => {
    const state = runStates[tool.name];
    let parsed: Record<string, any>;
    try {
      parsed = JSON.parse(state.args || "{}");
    } catch {
      setRunStates((prev) => ({
        ...prev,
        [tool.name]: { ...prev[tool.name], error: "Invalid JSON in arguments" },
      }));
      return;
    }

    setRunStates((prev) => ({
      ...prev,
      [tool.name]: { ...prev[tool.name], isRunning: true, error: null, result: null },
    }));

    try {
      const { result } = await api.callSFMcpTool(tool.name, parsed);
      setRunStates((prev) => ({
        ...prev,
        [tool.name]: { ...prev[tool.name], isRunning: false, result },
      }));
    } catch (err: any) {
      setRunStates((prev) => ({
        ...prev,
        [tool.name]: { ...prev[tool.name], isRunning: false, error: err.message },
      }));
    }
  };

  const defaultArgs = (tool: SFMcpTool): string => {
    const props = tool.inputSchema?.properties || {};
    const required: string[] = tool.inputSchema?.required || [];
    const example: Record<string, string> = {};
    for (const key of required) {
      const propType = props[key]?.type || "string";
      example[key] = propType === "number" ? "1" : propType === "boolean" ? "true" : "";
    }
    return JSON.stringify(example, null, 2);
  };

  return (
    <div className="space-y-6">
      <div className="flex items-start justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground">Salesforce MCP Tools</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Official Salesforce Hosted MCP — tools available to the Architect and directly runnable here
          </p>
        </div>
        <div className="flex items-center gap-2 rounded-lg border border-border bg-card px-3 py-2">
          <div
            className={cn(
              "h-2 w-2 rounded-full",
              isLoading ? "bg-yellow-400 animate-pulse" : connected ? "bg-green-400" : "bg-red-400"
            )}
          />
          <span className="text-xs text-muted-foreground">
            {isLoading ? "Connecting..." : connected ? `${tools.length} tools available` : "Not connected"}
          </span>
        </div>
      </div>

      {/* Connection error */}
      {!isLoading && !connected && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/5 p-5">
          <div className="flex items-start gap-3">
            <svg className="mt-0.5 h-5 w-5 shrink-0 text-destructive" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <circle cx="12" cy="12" r="10" />
              <line x1="12" y1="8" x2="12" y2="12" />
              <line x1="12" y1="16" x2="12.01" y2="16" />
            </svg>
            <div className="space-y-2">
              <p className="text-sm font-medium text-foreground">Could not connect to Salesforce Hosted MCP</p>
              {connectionError && (
                <p className="text-xs font-mono text-muted-foreground">{connectionError}</p>
              )}
              <p className="text-xs text-muted-foreground">
                Make sure your Connected App has the required scopes and that the External Client App is
                configured for MCP access. The endpoint used is:
              </p>
              <code className="block rounded bg-muted px-2 py-1 text-xs text-foreground">
                https://api.salesforce.com/platform/mcp/v1/platform/sobject-reads
              </code>
              <p className="text-xs text-muted-foreground">
                Required OAuth scope: <code className="text-foreground">sfap_api</code> or <code className="text-foreground">api</code>
              </p>
            </div>
          </div>
        </div>
      )}

      {/* Loading */}
      {isLoading && (
        <div className="flex items-center justify-center py-16">
          <div className="flex flex-col items-center gap-3">
            <div className="h-8 w-8 animate-spin rounded-full border-2 border-primary border-t-transparent" />
            <p className="text-sm text-muted-foreground">Connecting to Salesforce Hosted MCP...</p>
          </div>
        </div>
      )}

      {/* Tool list */}
      {!isLoading && connected && tools.length > 0 && (
        <div className="space-y-2">
          <p className="text-xs text-muted-foreground">
            These tools are automatically available to the AI Architect when you chat with it.
            You can also run them directly here to inspect raw Salesforce data.
          </p>
          {tools.map((tool) => {
            const state = runStates[tool.name];
            const isOpen = expanded === tool.name;

            return (
              <div
                key={tool.name}
                className="rounded-lg border border-border bg-card overflow-hidden"
              >
                {/* Tool header */}
                <button
                  onClick={() => toggleExpand(tool.name)}
                  className="flex w-full items-center justify-between px-4 py-3 text-left hover:bg-accent/30 transition-colors"
                >
                  <div className="flex items-center gap-3">
                    <span className="rounded bg-cyan-500/10 px-2 py-0.5 font-mono text-xs text-cyan-400">
                      {tool.name}
                    </span>
                    <span className="text-sm text-muted-foreground">{tool.description}</span>
                  </div>
                  <svg
                    className={cn("h-4 w-4 shrink-0 text-muted-foreground transition-transform", isOpen && "rotate-90")}
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                    strokeWidth={2}
                  >
                    <polyline points="9,18 15,12 9,6" />
                  </svg>
                </button>

                {/* Expanded tool runner */}
                {isOpen && state && (
                  <div className="border-t border-border px-4 pb-4 pt-3 space-y-3">
                    {/* Schema */}
                    <div>
                      <p className="mb-1 text-xs font-medium text-muted-foreground">Input Schema</p>
                      <pre className="max-h-40 overflow-auto rounded bg-muted px-3 py-2 text-xs text-foreground">
                        {JSON.stringify(tool.inputSchema, null, 2)}
                      </pre>
                    </div>

                    {/* Args textarea */}
                    <div>
                      <p className="mb-1 text-xs font-medium text-muted-foreground">
                        Arguments (JSON)
                      </p>
                      <textarea
                        value={state.args}
                        onChange={(e) =>
                          setRunStates((prev) => ({
                            ...prev,
                            [tool.name]: { ...prev[tool.name], args: e.target.value },
                          }))
                        }
                        onFocus={(e) => {
                          if (e.target.value === "{}") {
                            const def = defaultArgs(tool);
                            if (def !== "{}") {
                              setRunStates((prev) => ({
                                ...prev,
                                [tool.name]: { ...prev[tool.name], args: def },
                              }));
                            }
                          }
                        }}
                        rows={4}
                        className="w-full resize-y rounded border border-input bg-background px-3 py-2 font-mono text-xs text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-1 focus:ring-ring"
                        spellCheck={false}
                      />
                    </div>

                    <button
                      onClick={() => runTool(tool)}
                      disabled={state.isRunning}
                      className="rounded-lg bg-primary px-4 py-2 text-xs font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
                    >
                      {state.isRunning ? "Running..." : "Execute Tool"}
                    </button>

                    {/* Error */}
                    {state.error && (
                      <div className="rounded border border-destructive/30 bg-destructive/5 px-3 py-2 text-xs text-destructive">
                        {state.error}
                      </div>
                    )}

                    {/* Result */}
                    {state.result !== null && (
                      <div>
                        <p className="mb-1 text-xs font-medium text-muted-foreground">Result</p>
                        <pre className="max-h-64 overflow-auto rounded bg-muted px-3 py-2 text-xs text-foreground whitespace-pre-wrap">
                          {state.result}
                        </pre>
                      </div>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      {/* Empty — connected but no tools */}
      {!isLoading && connected && tools.length === 0 && (
        <div className="py-12 text-center text-sm text-muted-foreground">
          Connected, but no tools were returned by the Salesforce MCP server.
        </div>
      )}
    </div>
  );
}
