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
  const [usingCustomToken, setUsingCustomToken] = useState(false);
  const [connectionError, setConnectionError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [expanded, setExpanded] = useState<string | null>(null);
  const [runStates, setRunStates] = useState<Record<string, ToolRunState>>({});

  // Token override state
  const [showTokenForm, setShowTokenForm] = useState(false);
  const [tokenInput, setTokenInput] = useState("");
  const [savingToken, setSavingToken] = useState(false);
  const [tokenError, setTokenError] = useState<string | null>(null);

  const loadTools = () => {
    setIsLoading(true);
    api
      .getSFMcpTools()
      .then((res) => {
        setTools(res.tools);
        setConnected(res.connected);
        setUsingCustomToken(res.usingCustomToken || false);
        setConnectionError(res.error || null);
        if (!res.connected) setShowTokenForm(true);
      })
      .catch((err) => {
        setConnected(false);
        setConnectionError(err.message);
        setShowTokenForm(true);
      })
      .finally(() => setIsLoading(false));
  };

  useEffect(() => { loadTools(); }, []);

  const saveToken = async () => {
    if (!tokenInput.trim()) return;
    setSavingToken(true);
    setTokenError(null);
    try {
      await api.setSFMcpToken(tokenInput.trim());
      setTokenInput("");
      setShowTokenForm(false);
      loadTools();
    } catch (err: any) {
      setTokenError(err.message);
    } finally {
      setSavingToken(false);
    }
  };

  const clearToken = async () => {
    await api.clearSFMcpToken().catch(() => {});
    setUsingCustomToken(false);
    loadTools();
  };

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
      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground">Salesforce MCP Tools</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Official Salesforce Hosted MCP — tools are also available to the AI Architect automatically
          </p>
        </div>
        <div className="flex items-center gap-2">
          {usingCustomToken && (
            <button
              onClick={clearToken}
              className="rounded border border-border px-2 py-1 text-xs text-muted-foreground hover:text-foreground"
            >
              Clear token
            </button>
          )}
          <div className="flex items-center gap-2 rounded-lg border border-border bg-card px-3 py-2">
            <div
              className={cn(
                "h-2 w-2 rounded-full",
                isLoading
                  ? "animate-pulse bg-yellow-400"
                  : connected
                  ? "bg-green-400"
                  : "bg-red-400"
              )}
            />
            <span className="text-xs text-muted-foreground">
              {isLoading
                ? "Connecting..."
                : connected
                ? `${tools.length} tools${usingCustomToken ? " · custom token" : ""}`
                : "Not connected"}
            </span>
          </div>
        </div>
      </div>

      {/* Token setup panel */}
      {showTokenForm && (
        <div className="rounded-lg border border-border bg-card p-5 space-y-4">
          <div>
            <h2 className="text-sm font-semibold text-foreground">Configure MCP Access Token</h2>
            <p className="mt-1 text-xs text-muted-foreground">
              Your main session token doesn't have the <code className="text-foreground">sfap_api</code> scope
              required by Salesforce's AI MCP APIs. Provide a token from your External Client App instead.
            </p>
          </div>

          {connectionError && (
            <div className="rounded border border-destructive/30 bg-destructive/5 px-3 py-2 font-mono text-xs text-destructive">
              {connectionError}
            </div>
          )}

          <div className="rounded-lg border border-border bg-muted/30 p-4 space-y-2 text-xs text-muted-foreground">
            <p className="font-medium text-foreground">How to get a token from your External Client App:</p>
            <ol className="list-decimal list-inside space-y-1">
              <li>In Salesforce Setup → External Client Apps, open your MCP-enabled app</li>
              <li>Make sure the app has the <code className="text-foreground">sfap_api</code> OAuth scope enabled</li>
              <li>Use the Salesforce CLI to get a token:
                <pre className="mt-1 rounded bg-muted px-2 py-1 text-foreground">sf org display --json</pre>
              </li>
              <li>Copy the <code className="text-foreground">accessToken</code> value and paste it below</li>
            </ol>
            <p className="pt-1">
              Or re-authenticate to your main Connected App after adding the{" "}
              <code className="text-foreground">sfap_api</code> scope — then log out and back in to this app.
            </p>
          </div>

          <div className="flex gap-2">
            <input
              type="password"
              value={tokenInput}
              onChange={(e) => setTokenInput(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && saveToken()}
              placeholder="Paste your access token here..."
              className="flex-1 rounded-lg border border-input bg-background px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-1 focus:ring-ring font-mono"
            />
            <button
              onClick={saveToken}
              disabled={!tokenInput.trim() || savingToken}
              className="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
            >
              {savingToken ? "Saving..." : "Save & Connect"}
            </button>
          </div>
          {tokenError && (
            <p className="text-xs text-destructive">{tokenError}</p>
          )}

          {connected && (
            <button
              onClick={() => setShowTokenForm(false)}
              className="text-xs text-muted-foreground hover:text-foreground"
            >
              Already connected — hide this
            </button>
          )}
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
          <div className="flex items-center justify-between">
            <p className="text-xs text-muted-foreground">
              These tools are automatically available to the AI Architect. Run them directly here to inspect raw Salesforce data.
            </p>
            <button
              onClick={() => setShowTokenForm((v) => !v)}
              className="text-xs text-muted-foreground hover:text-foreground"
            >
              {showTokenForm ? "Hide token settings" : "Change token"}
            </button>
          </div>

          {tools.map((tool) => {
            const state = runStates[tool.name];
            const isOpen = expanded === tool.name;

            return (
              <div key={tool.name} className="rounded-lg border border-border bg-card overflow-hidden">
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
                    fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}
                  >
                    <polyline points="9,18 15,12 9,6" />
                  </svg>
                </button>

                {isOpen && state && (
                  <div className="border-t border-border px-4 pb-4 pt-3 space-y-3">
                    <div>
                      <p className="mb-1 text-xs font-medium text-muted-foreground">Input Schema</p>
                      <pre className="max-h-40 overflow-auto rounded bg-muted px-3 py-2 text-xs text-foreground">
                        {JSON.stringify(tool.inputSchema, null, 2)}
                      </pre>
                    </div>
                    <div>
                      <p className="mb-1 text-xs font-medium text-muted-foreground">Arguments (JSON)</p>
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
                        className="w-full resize-y rounded border border-input bg-background px-3 py-2 font-mono text-xs text-foreground focus:outline-none focus:ring-1 focus:ring-ring"
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
                    {state.error && (
                      <div className="rounded border border-destructive/30 bg-destructive/5 px-3 py-2 text-xs text-destructive">
                        {state.error}
                      </div>
                    )}
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

      {!isLoading && connected && tools.length === 0 && (
        <div className="py-12 text-center text-sm text-muted-foreground">
          Connected, but no tools were returned by the Salesforce MCP server.
        </div>
      )}
    </div>
  );
}
