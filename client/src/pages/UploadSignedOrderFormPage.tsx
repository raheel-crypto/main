import { useCallback, useEffect, useRef, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { cn } from "../lib/utils";
import { api, CloseDocOpportunity } from "../lib/api";

interface Props {
  instanceUrl: string;
}

/**
 * Landing page for the "Upload signed order form" button on the agent close
 * cards. Takes ?opp=<Opportunity Id>, shows what is already attached, uploads
 * the chosen file as a __signed ContentVersion linked to the opportunity, and
 * sends the rep back to the agent to check readiness again.
 */
export function UploadSignedOrderFormPage({ instanceUrl }: Props) {
  const [params] = useSearchParams();
  const oppId = (params.get("opp") || "").trim();

  const [opp, setOpp] = useState<CloseDocOpportunity | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const [file, setFile] = useState<File | null>(null);
  const [dragging, setDragging] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [uploadedTitle, setUploadedTitle] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!oppId) {
      setLoading(false);
      setLoadError("This page needs an opportunity. Open it from the Upload signed order form button on the close card.");
      return;
    }
    setLoading(true);
    api
      .getCloseDocOpportunity(oppId)
      .then(setOpp)
      .catch((err) => setLoadError(err.message))
      .finally(() => setLoading(false));
  }, [oppId]);

  const choose = useCallback((f: File | null) => {
    setFile(f);
    setUploadError(null);
    setUploadedTitle(null);
  }, []);

  const handleUpload = async () => {
    if (!file || !oppId) return;
    setUploading(true);
    setUploadError(null);
    try {
      const result = await api.uploadSignedOrderForm(oppId, file);
      setUploadedTitle(result.title);
      setOpp(result.opportunity);
      setFile(null);
      if (inputRef.current) inputRef.current.value = "";
    } catch (err: any) {
      setUploadError(err.message);
    } finally {
      setUploading(false);
    }
  };

  const recordUrl = oppId ? `${instanceUrl}/${oppId}` : instanceUrl;

  return (
    <div className="flex min-h-screen items-start justify-center bg-background px-4 py-10">
      <div className="w-full max-w-xl space-y-6">
        <div className="space-y-1">
          <p className="text-xs font-medium uppercase tracking-wider text-muted-foreground">Agent close tools</p>
          <h1 className="text-2xl font-bold text-foreground">Attach the signed order form</h1>
          <p className="text-sm text-muted-foreground">
            The file is saved to the opportunity in Salesforce with the <code className="text-foreground">__signed</code>{" "}
            name the close checks look for. When it is done, go back to the agent and ask it to check the deal again.
          </p>
        </div>

        {loading && <div className="rounded-xl border border-border bg-card p-6 text-sm text-muted-foreground">Loading the opportunity…</div>}

        {!loading && loadError && (
          <div className="rounded-xl border border-destructive/50 bg-card p-6 text-sm text-destructive">{loadError}</div>
        )}

        {!loading && opp && (
          <>
            <div className="rounded-xl border border-border bg-card p-6">
              <div className="flex items-start justify-between gap-4">
                <div>
                  <div className="text-lg font-semibold text-foreground">{opp.name}</div>
                  <div className="text-sm text-muted-foreground">{opp.accountName ?? "No account"}</div>
                </div>
                <span className="rounded-full border border-border px-3 py-1 text-xs text-muted-foreground">{opp.stageName}</span>
              </div>

              <div className="mt-5">
                <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground">Signed documents on this deal</div>
                {opp.signedDocuments.length === 0 ? (
                  <p className="mt-2 text-sm text-muted-foreground">None yet. Closed Won is blocked until one is attached.</p>
                ) : (
                  <ul className="mt-2 space-y-1">
                    {opp.signedDocuments.map((d) => (
                      <li key={d.contentDocumentId} className="flex items-center gap-2 text-sm text-foreground">
                        <svg className="h-4 w-4 shrink-0 text-emerald-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                          <polyline points="20,6 9,17 4,12" />
                        </svg>
                        <span>
                          {d.title}
                          {d.fileExtension ? `.${d.fileExtension}` : ""}
                        </span>
                        <span className="text-xs text-muted-foreground">{new Date(d.createdDate).toLocaleDateString()}</span>
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            </div>

            {opp.isClosed ? (
              <div className="rounded-xl border border-border bg-card p-6 text-sm text-muted-foreground">
                This opportunity is already closed, so nothing further is needed here.
              </div>
            ) : (
              <div className="rounded-xl border border-border bg-card p-6">
                <div
                  onDragOver={(e) => {
                    e.preventDefault();
                    setDragging(true);
                  }}
                  onDragLeave={() => setDragging(false)}
                  onDrop={(e) => {
                    e.preventDefault();
                    setDragging(false);
                    choose(e.dataTransfer.files?.[0] ?? null);
                  }}
                  onClick={() => inputRef.current?.click()}
                  className={cn(
                    "flex cursor-pointer flex-col items-center justify-center rounded-lg border-2 border-dashed px-6 py-10 text-center transition-colors",
                    dragging ? "border-primary bg-primary/5" : "border-border hover:border-primary/60"
                  )}
                >
                  <svg className="mb-3 h-8 w-8 text-muted-foreground" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                    <path d="M12 16V4m0 0l-4 4m4-4l4 4M4 16v2a2 2 0 002 2h12a2 2 0 002-2v-2" />
                  </svg>
                  {file ? (
                    <div className="text-sm text-foreground">{file.name}</div>
                  ) : (
                    <>
                      <div className="text-sm text-foreground">Drop the signed order form here, or click to choose</div>
                      <div className="mt-1 text-xs text-muted-foreground">PDF or any document, up to 25 MB</div>
                    </>
                  )}
                  <input
                    ref={inputRef}
                    type="file"
                    className="hidden"
                    onChange={(e) => choose(e.target.files?.[0] ?? null)}
                  />
                </div>

                {file && (
                  <p className="mt-3 text-xs text-muted-foreground">
                    Will be saved as <span className="text-foreground">__signed {file.name}</span>
                  </p>
                )}

                {uploadError && <p className="mt-3 text-sm text-destructive">{uploadError}</p>}

                <button
                  onClick={handleUpload}
                  disabled={!file || uploading}
                  className={cn(
                    "mt-4 inline-flex w-full items-center justify-center rounded-lg px-6 py-3 text-sm font-medium text-white transition-colors",
                    !file || uploading ? "cursor-not-allowed bg-secondary text-muted-foreground" : "bg-sf-blue hover:bg-sf-blue/90"
                  )}
                >
                  {uploading ? "Uploading…" : "Upload to the opportunity"}
                </button>
              </div>
            )}

            {uploadedTitle && (
              <div className="rounded-xl border border-emerald-500/40 bg-card p-6">
                <div className="text-sm font-semibold text-emerald-400">Attached: {uploadedTitle}</div>
                <p className="mt-2 text-sm text-muted-foreground">
                  Go back to the agent and say <span className="text-foreground">"check the deal again"</span>, or click Check
                  again on the card. Closed Won is no longer blocked by the order form.
                </p>
              </div>
            )}

            <div className="text-center">
              <a href={recordUrl} target="_blank" rel="noreferrer" className="text-sm text-sf-blue hover:underline">
                Open the opportunity in Salesforce
              </a>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
