import { useState, useEffect } from "react";
import { useSearchParams } from "react-router-dom";
import { cn } from "../lib/utils";
import { api, SFMcpTool } from "../lib/api";

interface ToolRunState {
  args: string;
  result: string | null;
  isRunning: boolean;
  error: string | null;
}

export function SFMcpPage() {
  const [searchParams, setSearchParams] = useSearchParams();

  const [mcpConfigured, setMcpConfigured] = useState(false);
  const [mcpOAuthConnected, setMcpOAuthConnected] = useState(false);
  const [tools, setTools] = useState<SFMcpTool[]>([]);
  const [connected, setConnected] = useState(false);
  const [usingCustomToken, setUsingCustomToken] = useState(false);
  const [connectionError, setConnectionError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [expanded, setExpanded] = useState<string | null>(null);
  const [runStates, setRunStates] = useState<Record<string, ToolRunState>>({});

  // Manual token paste fallback
  const [showTokenForm, setShowTokenForm] = useState(false);
  const [tokenInput, setTokenInput] = useState("");
  const [savingToken, setSavingToken] = useState(false);
  const [tokenError, setTokenError] = useState<string | null>(null);

  // OAuth result from redirect
  const oauthSuccess = searchParams.get("mcpConnected") === "true";
  const oauthError = searchParams.get("error");

  // Clear URL params after reading
  useEffect(() => {
    if (oauthSuccess || oauthError) {
      setSearchParams({}, { replace: true });
    }
  }, []);

  const loadAll = () => {
    setIsLoading(true);
    Promise.all([api.getMcpAuthStatus(), api.getSFMcpTools()])
      .then(([authStatus, toolsRes]) => {
        setMcpConfigured(authStatus.configured);
        setMcpOAuthConnected(authStatus.connected);
        setTools(toolsRes.tools);
        setConnected(toolsRes.connected);
        setUsingCustomToken(toolsRes.usingCustomToken || false);
        setConnectionError(toolsRes.error || null);
      })
      .catch((err) => {
        setConnected(false);
        setConnectionError(err.message);
      })
      .finally(() => setIsLoading(false));
  };

  useEffect(() => { loadAll(); }, []);

  const saveToken = async () => {
    if (!tokenInput.trim()) return;
    setSavingToken(true);
    setTokenError(null);
    try {
      await api.setSFMcpToken(tokenInput.trim());
      setTokenInput("");
      setShowTokenForm(false);
      loadAll();
    } catch (err: any) {
      setTokenError(err.message);
    } finally {
      setSavingToken(false);
    }
  };

  const clearToken = async () => {
    await api.clearSFMcpToken().catch(() => {});
    loadAll();
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
            <div className={cn(
              "h-2 w-2 rounded-full",
              isLoading ? "animate-pulse bg-yellow-400" : connected ? "bg-green-400" : "bg-red-400"
            )} />
            <span className="text-xs text-muted-foreground">
              {isLoading ? "Connecting..." : connected
                ? `${tools.length} tools${usingCustomToken ? " · custom token" : ""}`
                : "Not connected"}
            </span>
          </div>
        </div>
      </div>

      {/* OAuth success banner */}
      {oauthSuccess && (
        <div className="rounded-lg border border-green-500/20 bg-green-500/5 px-4 py-3 text-sm text-green-400">
          External Client App connected successfully.
        </div>
      )}

      {/* OAuth error banner */}
      {oauthError && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/5 px-4 py-3 text-sm text-destructive">
          OAuth error: {decodeURIComponent(oauthError)}
        </div>
      )}

      {/* Auth setup panel — shown when not connected */}
      {!isLoading && !connected && (
        <div className="rounded-lg border border-border bg-card p-5 space-y-5">
          <div>
            <h2 className="text-sm font-semibold text-foreground">Connect to Salesforce Hosted MCP</h2>
            <p className="mt-1 text-xs text-muted-foreground">
              The Salesforce Hosted MCP requires a token from an External Client App with the{" "}
              <code className="text-foreground">sfap_api</code> scope — different from your main Connected App.
            </p>
          </div>

          {connectionError && (
            <div className="rounded border border-border bg-muted px-3 py-2 font-mono text-xs text-muted-foreground">
              {connectionError}
            </div>
          )}

          {/* Option 1: OAuth with External Client App */}
          <div className="rounded-lg border border-border p-4 space-y-3">
            <div className="flex items-center gap-2">
              <span className="rounded bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary">
                Option 1 — Recommended
              </span>
              <span className="text-xs text-muted-foreground">OAuth via External Client App</span>
            </div>

            {mcpConfigured ? (
              <div className="space-y-2">
                <p className="text-xs text-muted-foreground">
                  Your External Client App is configured. Click below to authenticate — you'll be
                  redirected to Salesforce and back.
                </p>
                <a
                  href="/auth/mcp-login"
                  className="inline-flex items-center gap-2 rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90"
                >
                  <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4M10 17l5-5-5-5M13 12H3" />
                  </svg>
                  Connect External Client App
                </a>
              </div>
            ) : (
              <div className="space-y-2">
                <p className="text-xs text-muted-foreground">
                  Add your External Client App credentials to <code className="text-foreground">.env</code>:
                </p>
                <pre className="rounded bg-muted px-3 py-2 text-xs text-foreground">{`SF_MCP_CLIENT_ID=<your_consumer_key>
SF_MCP_CLIENT_SECRET=<your_consumer_secret>`}</pre>
                <p className="text-xs text-muted-foreground">
                  In Setup → External Client Apps → open your app → copy the Consumer Key and Secret.
                  Also add <code className="text-foreground">http://localhost:3001/auth/mcp-callback</code> as
                  an allowed callback URL on the app.
                </p>
                <p className="text-xs text-muted-foreground">
                  After updating <code className="text-foreground">.env</code>, restart the server.
                </p>
              </div>
            )}
          </div>

          {/* Option 2: Manual token paste */}
          <div className="rounded-lg border border-border p-4 space-y-3">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <span className="rounded bg-muted px-2 py-0.5 text-xs font-medium text-muted-foreground">
                  Option 2
                </span>
                <span className="text-xs text-muted-foreground">Paste an access token manually</span>
              </div>
              <button
                onClick={() => setShowTokenForm((v) => !v)}
                className="text-xs text-muted-foreground hover:text-foreground"
              >
                {showTokenForm ? "Hide" : "Show"}
              </button>
            </div>

            {showTokenForm && (
              <div className="space-y-2">
                <p className="text-xs text-muted-foreground">
                  Run <code className="text-foreground">sf org display --json</code> in your terminal
                  (authenticated to the org via your External Client App) and paste the{" "}
                  <code className="text-foreground">accessToken</code> below.
                </p>
                <div className="flex gap-2">
                  <input
                    type="password"
                    value={tokenInput}
                    onChange={(e) => setTokenInput(e.target.value)}
                    onKeyDown={(e) => e.key === "Enter" && saveToken()}
                    placeholder="Paste access token..."
                    className="flex-1 rounded border border-input bg-background px-3 py-2 text-sm font-mono text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-1 focus:ring-ring"
                  />
                  <button
                    onClick={saveToken}
                    disabled={!tokenInput.trim() || savingToken}
                    className="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
                  >
                    {savingToken ? "Saving..." : "Connect"}
                  </button>
                </div>
                {tokenError && <p className="text-xs text-destructive">{tokenError}</p>}
              </div>
            )}
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
          <div className="flex items-center justify-between">
            <p className="text-xs text-muted-foreground">
              These tools are automatically available to the AI Architect. Run them here to inspect raw data.
            </p>
            <button
              onClick={clearToken}
              className="text-xs text-muted-foreground hover:text-foreground"
            >
              Disconnect
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
