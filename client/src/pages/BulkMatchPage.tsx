import { useState, useEffect, useRef, useCallback } from "react";
import { cn } from "../lib/utils";
import { api, BulkField, BulkJobStatus } from "../lib/api";

type Step = "upload" | "configure" | "matching" | "review" | "map" | "updating" | "results";

interface FieldMap {
  csvColumn: string;
  sfField: string;
}

export function BulkMatchPage() {
  const [step, setStep] = useState<Step>("upload");

  // Upload state
  const [file, setFile] = useState<File | null>(null);
  const [jobId, setJobId] = useState<string | null>(null);
  const [headers, setHeaders] = useState<string[]>([]);
  const [preview, setPreview] = useState<Record<string, string>[]>([]);
  const [rowCount, setRowCount] = useState(0);
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState<string | null>(null);

  // Configure state
  const [objects, setObjects] = useState<{ name: string; label: string; custom: boolean }[]>([]);
  const [objectName, setObjectName] = useState("");
  const [objectSearch, setObjectSearch] = useState("");
  const [matchFields, setMatchFields] = useState<BulkField[]>([]);
  const [writableFields, setWritableFields] = useState<BulkField[]>([]);
  const [csvColumn, setCsvColumn] = useState("");
  const [sfField, setSfField] = useState("");
  const [loadingFields, setLoadingFields] = useState(false);

  // Matching/update progress
  const [jobStatus, setJobStatus] = useState<BulkJobStatus | null>(null);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);

  // Results
  const [matchedPreview, setMatchedPreview] = useState<any[]>([]);
  const [unmatchedPreview, setUnmatchedPreview] = useState<any[]>([]);
  const [duplicatePreview, setDuplicatePreview] = useState<any[]>([]);
  const [updateFailures, setUpdateFailures] = useState<any[]>([]);

  // Field mapping
  const [fieldMappings, setFieldMappings] = useState<FieldMap[]>([{ csvColumn: "", sfField: "" }]);

  const [error, setError] = useState<string | null>(null);

  // Cleanup polling on unmount
  useEffect(() => {
    return () => {
      if (pollRef.current) clearInterval(pollRef.current);
    };
  }, []);

  const handleUpload = async () => {
    if (!file) return;
    setUploading(true);
    setUploadError(null);
    try {
      const result = await api.uploadBulkCSV(file);
      setJobId(result.jobId);
      setHeaders(result.headers);
      setPreview(result.preview);
      setRowCount(result.rowCount);
      setStep("configure");
      // Pre-load objects
      const objs = await api.getBulkObjects();
      setObjects(objs);
    } catch (err: any) {
      setUploadError(err.message);
    } finally {
      setUploading(false);
    }
  };

  const handleObjectSelect = async (name: string) => {
    setObjectName(name);
    setLoadingFields(true);
    setSfField("");
    try {
      const { matchFields: mf, writableFields: wf } = await api.getBulkFields(name);
      setMatchFields(mf);
      setWritableFields(wf);
    } catch (err: any) {
      setError(err.message);
    } finally {
      setLoadingFields(false);
    }
  };

  const startPolling = useCallback(
    (targetStatus: string, onComplete: () => void) => {
      if (!jobId) return;
      pollRef.current = setInterval(async () => {
        try {
          const status = await api.getBulkJobStatus(jobId);
          setJobStatus(status);
          if (status.status === targetStatus || status.status === "error") {
            if (pollRef.current) clearInterval(pollRef.current);
            pollRef.current = null;
            onComplete();
          }
        } catch {
          // Keep polling
        }
      }, 1500);
    },
    [jobId]
  );

  const handleStartMatch = async () => {
    if (!jobId || !objectName || !csvColumn || !sfField) return;
    setStep("matching");
    setJobStatus(null);
    try {
      await api.startBulkMatch(jobId, objectName, csvColumn, sfField);
      startPolling("matched", async () => {
        const results = await api.getBulkJobResults(jobId);
        setMatchedPreview(results.matched.slice(0, 50));
        setUnmatchedPreview(results.unmatched.slice(0, 50));
        setDuplicatePreview(results.duplicates.slice(0, 50));
        setStep("review");
      });
    } catch (err: any) {
      setError(err.message);
      setStep("configure");
    }
  };

  const handleStartUpdate = async () => {
    if (!jobId || !objectName) return;
    const validMappings = fieldMappings.filter((m) => m.csvColumn && m.sfField);
    if (validMappings.length === 0) return;

    setStep("updating");
    setJobStatus(null);
    try {
      await api.startBulkUpdate(jobId, objectName, validMappings);
      startPolling("complete", async () => {
        const results = await api.getBulkJobResults(jobId);
        setUpdateFailures(results.updateFailures || []);
        setStep("results");
      });
    } catch (err: any) {
      setError(err.message);
      setStep("map");
    }
  };

  const addMapping = () => setFieldMappings([...fieldMappings, { csvColumn: "", sfField: "" }]);
  const removeMapping = (i: number) => setFieldMappings(fieldMappings.filter((_, idx) => idx !== i));
  const updateMapping = (i: number, key: keyof FieldMap, value: string) => {
    const updated = [...fieldMappings];
    updated[i] = { ...updated[i], [key]: value };
    setFieldMappings(updated);
  };

  const reset = () => {
    setStep("upload");
    setFile(null);
    setJobId(null);
    setHeaders([]);
    setPreview([]);
    setRowCount(0);
    setObjectName("");
    setCsvColumn("");
    setSfField("");
    setJobStatus(null);
    setFieldMappings([{ csvColumn: "", sfField: "" }]);
    setError(null);
  };

  const filteredObjects = objectSearch
    ? objects.filter(
        (o) =>
          o.label.toLowerCase().includes(objectSearch.toLowerCase()) ||
          o.name.toLowerCase().includes(objectSearch.toLowerCase())
      )
    : objects;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground">Bulk Match & Update</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Upload a CSV, match records against Salesforce, then bulk update matched records
        </p>
      </div>

      {/* Step indicator */}
      <div className="flex items-center gap-2 text-xs">
        {(["upload", "configure", "matching", "review", "map", "updating", "results"] as Step[]).map(
          (s, i) => (
            <div key={s} className="flex items-center gap-2">
              {i > 0 && <div className="h-px w-4 bg-border" />}
              <div
                className={cn(
                  "rounded-full px-3 py-1 font-medium capitalize",
                  step === s
                    ? "bg-primary text-primary-foreground"
                    : ["upload", "configure", "matching", "review", "map", "updating", "results"].indexOf(step) > i
                    ? "bg-green-500/10 text-green-400"
                    : "bg-muted text-muted-foreground"
                )}
              >
                {s}
              </div>
            </div>
          )
        )}
      </div>

      {error && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/5 px-4 py-3 text-sm text-destructive">
          {error}
          <button onClick={() => setError(null)} className="ml-2 underline">dismiss</button>
        </div>
      )}

      {/* Step 1: Upload */}
      {step === "upload" && (
        <div className="rounded-xl border border-border bg-card p-8">
          <div className="mx-auto max-w-lg space-y-4">
            <div
              onDragOver={(e) => { e.preventDefault(); e.stopPropagation(); }}
              onDrop={(e) => {
                e.preventDefault();
                e.stopPropagation();
                const f = e.dataTransfer.files[0];
                if (f && f.name.endsWith(".csv")) setFile(f);
              }}
              className="flex flex-col items-center justify-center rounded-lg border-2 border-dashed border-border p-12 transition-colors hover:border-primary/50"
            >
              <svg className="mb-3 h-10 w-10 text-muted-foreground" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                <path d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12" />
              </svg>
              <p className="text-sm text-muted-foreground">
                Drag & drop a CSV file here, or
              </p>
              <label className="mt-2 cursor-pointer rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90">
                Browse Files
                <input
                  type="file"
                  accept=".csv"
                  className="hidden"
                  onChange={(e) => setFile(e.target.files?.[0] || null)}
                />
              </label>
            </div>

            {file && (
              <div className="flex items-center justify-between rounded-lg border border-border bg-muted/30 px-4 py-3">
                <div>
                  <p className="text-sm font-medium text-foreground">{file.name}</p>
                  <p className="text-xs text-muted-foreground">
                    {(file.size / 1024 / 1024).toFixed(2)} MB
                  </p>
                </div>
                <button
                  onClick={handleUpload}
                  disabled={uploading}
                  className="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
                >
                  {uploading ? "Uploading..." : "Upload & Parse"}
                </button>
              </div>
            )}

            {uploadError && (
              <p className="text-sm text-destructive">{uploadError}</p>
            )}
          </div>
        </div>
      )}

      {/* Step 2: Configure Match */}
      {step === "configure" && (
        <div className="space-y-4">
          {/* CSV Preview */}
          <div className="rounded-lg border border-border bg-card p-4">
            <div className="mb-2 flex items-center justify-between">
              <p className="text-sm font-medium text-foreground">CSV Preview</p>
              <span className="text-xs text-muted-foreground">{rowCount.toLocaleString()} rows</span>
            </div>
            <div className="overflow-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="border-b border-border">
                    {headers.map((h) => (
                      <th key={h} className="px-3 py-2 text-left font-medium text-muted-foreground">{h}</th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {preview.map((row, i) => (
                    <tr key={i} className="border-b border-border/50">
                      {headers.map((h) => (
                        <td key={h} className="px-3 py-2 text-foreground">{row[h]}</td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          {/* Match configuration */}
          <div className="rounded-lg border border-border bg-card p-6 space-y-4">
            <h3 className="text-sm font-semibold text-foreground">Configure Matching</h3>

            <div className="grid grid-cols-3 gap-4">
              <div className="space-y-1">
                <label className="text-xs font-medium text-muted-foreground">Salesforce Object</label>
                <input
                  type="text"
                  placeholder="Search objects..."
                  value={objectSearch}
                  onChange={(e) => setObjectSearch(e.target.value)}
                  className="mb-1 w-full rounded border border-input bg-background px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-1 focus:ring-ring"
                />
                <select
                  value={objectName}
                  onChange={(e) => handleObjectSelect(e.target.value)}
                  size={6}
                  className="w-full rounded border border-input bg-background px-2 py-1 text-sm text-foreground"
                >
                  {filteredObjects.slice(0, 100).map((o) => (
                    <option key={o.name} value={o.name}>
                      {o.label} ({o.name})
                    </option>
                  ))}
                </select>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-medium text-muted-foreground">CSV Column to Match</label>
                <select
                  value={csvColumn}
                  onChange={(e) => setCsvColumn(e.target.value)}
                  className="w-full rounded border border-input bg-background px-3 py-2 text-sm text-foreground"
                >
                  <option value="">Select column...</option>
                  {headers.map((h) => (
                    <option key={h} value={h}>{h}</option>
                  ))}
                </select>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-medium text-muted-foreground">Salesforce Field to Match Against</label>
                {loadingFields ? (
                  <p className="py-2 text-xs text-muted-foreground">Loading fields...</p>
                ) : (
                  <select
                    value={sfField}
                    onChange={(e) => setSfField(e.target.value)}
                    className="w-full rounded border border-input bg-background px-3 py-2 text-sm text-foreground"
                    disabled={!objectName}
                  >
                    <option value="">Select field...</option>
                    {matchFields.map((f) => (
                      <option key={f.name} value={f.name}>
                        {f.label} ({f.name}) — {f.type}
                      </option>
                    ))}
                  </select>
                )}
              </div>
            </div>

            <div className="flex gap-2">
              <button onClick={() => setStep("upload")} className="rounded-lg border border-border px-4 py-2 text-sm text-muted-foreground hover:text-foreground">
                Back
              </button>
              <button
                onClick={handleStartMatch}
                disabled={!objectName || !csvColumn || !sfField}
                className="rounded-lg bg-primary px-6 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
              >
                Start Matching ({rowCount.toLocaleString()} rows)
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Step 3: Matching Progress */}
      {step === "matching" && (
        <div className="rounded-xl border border-border bg-card p-8 text-center space-y-4">
          <div className="mx-auto h-10 w-10 animate-spin rounded-full border-3 border-primary border-t-transparent" />
          <h2 className="text-lg font-semibold text-foreground">Matching Records...</h2>
          <div className="mx-auto max-w-md">
            <div className="h-3 w-full overflow-hidden rounded-full bg-muted">
              <div
                className="h-full rounded-full bg-primary transition-all duration-500"
                style={{ width: `${jobStatus?.progress || 0}%` }}
              />
            </div>
            <p className="mt-2 text-sm text-muted-foreground">
              {jobStatus?.progress || 0}% — checking {rowCount.toLocaleString()} records against {objectName}
            </p>
            {jobStatus && jobStatus.matched > 0 && (
              <p className="text-xs text-green-400">{jobStatus.matched.toLocaleString()} matched so far</p>
            )}
          </div>
        </div>
      )}

      {/* Step 4: Review Results */}
      {step === "review" && jobStatus && (
        <div className="space-y-4">
          <div className="grid grid-cols-3 gap-4">
            <div className="rounded-lg border border-green-500/20 bg-green-500/5 p-4">
              <div className="text-2xl font-bold text-green-400">{jobStatus.matched.toLocaleString()}</div>
              <div className="text-xs text-muted-foreground">Matched</div>
            </div>
            <div className="rounded-lg border border-red-500/20 bg-red-500/5 p-4">
              <div className="text-2xl font-bold text-red-400">{jobStatus.unmatched.toLocaleString()}</div>
              <div className="text-xs text-muted-foreground">Unmatched</div>
            </div>
            <div className="rounded-lg border border-yellow-500/20 bg-yellow-500/5 p-4">
              <div className="text-2xl font-bold text-yellow-400">{jobStatus.duplicates.toLocaleString()}</div>
              <div className="text-xs text-muted-foreground">Duplicates (multiple SF matches)</div>
            </div>
          </div>

          {/* Matched preview */}
          {matchedPreview.length > 0 && (
            <div className="rounded-lg border border-border bg-card p-4">
              <p className="mb-2 text-sm font-medium text-foreground">
                Matched Records (first {Math.min(50, matchedPreview.length)})
              </p>
              <div className="max-h-48 overflow-auto">
                <table className="w-full text-xs">
                  <thead>
                    <tr className="border-b border-border">
                      <th className="px-3 py-2 text-left text-muted-foreground">SF ID</th>
                      <th className="px-3 py-2 text-left text-muted-foreground">SF Name</th>
                      {headers.slice(0, 4).map((h) => (
                        <th key={h} className="px-3 py-2 text-left text-muted-foreground">{h}</th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {matchedPreview.map((m, i) => (
                      <tr key={i} className="border-b border-border/50">
                        <td className="px-3 py-1.5 font-mono text-foreground">{m.sfId}</td>
                        <td className="px-3 py-1.5 text-foreground">{m.sfName}</td>
                        {headers.slice(0, 4).map((h) => (
                          <td key={h} className="px-3 py-1.5 text-foreground">{m.csvRow?.[h]}</td>
                        ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}

          {/* Unmatched download */}
          {jobStatus.unmatched > 0 && (
            <a
              href={`/api/bulk/jobs/${jobId}/unmatched`}
              className="inline-flex items-center gap-1 text-xs text-primary hover:underline"
            >
              Download {jobStatus.unmatched.toLocaleString()} unmatched rows as CSV
            </a>
          )}

          <div className="flex gap-2">
            <button onClick={reset} className="rounded-lg border border-border px-4 py-2 text-sm text-muted-foreground hover:text-foreground">
              Start Over
            </button>
            {jobStatus.matched > 0 && (
              <button
                onClick={() => setStep("map")}
                className="rounded-lg bg-primary px-6 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90"
              >
                Map Fields & Update ({jobStatus.matched.toLocaleString()} records)
              </button>
            )}
          </div>
        </div>
      )}

      {/* Step 5: Field Mapping */}
      {step === "map" && (
        <div className="space-y-4">
          <div className="rounded-lg border border-border bg-card p-6 space-y-4">
            <h3 className="text-sm font-semibold text-foreground">Map CSV Columns to Salesforce Fields</h3>
            <p className="text-xs text-muted-foreground">
              Choose which CSV columns to write into which Salesforce fields on the {jobStatus?.matched.toLocaleString()} matched records.
            </p>

            <div className="space-y-2">
              {fieldMappings.map((mapping, i) => (
                <div key={i} className="flex items-center gap-3">
                  <select
                    value={mapping.csvColumn}
                    onChange={(e) => updateMapping(i, "csvColumn", e.target.value)}
                    className="flex-1 rounded border border-input bg-background px-3 py-2 text-sm text-foreground"
                  >
                    <option value="">CSV Column...</option>
                    {headers.map((h) => (
                      <option key={h} value={h}>{h}</option>
                    ))}
                  </select>
                  <svg className="h-4 w-4 shrink-0 text-muted-foreground" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path d="M5 12h14M12 5l7 7-7 7" />
                  </svg>
                  <select
                    value={mapping.sfField}
                    onChange={(e) => updateMapping(i, "sfField", e.target.value)}
                    className="flex-1 rounded border border-input bg-background px-3 py-2 text-sm text-foreground"
                  >
                    <option value="">Salesforce Field...</option>
                    {writableFields.map((f) => (
                      <option key={f.name} value={f.name}>
                        {f.label} ({f.name}) — {f.type}
                      </option>
                    ))}
                  </select>
                  {fieldMappings.length > 1 && (
                    <button
                      onClick={() => removeMapping(i)}
                      className="rounded p-1 text-muted-foreground hover:text-destructive"
                    >
                      <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path d="M6 18L18 6M6 6l12 12" />
                      </svg>
                    </button>
                  )}
                </div>
              ))}
            </div>

            <button
              onClick={addMapping}
              className="text-xs text-primary hover:underline"
            >
              + Add another mapping
            </button>

            <div className="flex gap-2 pt-2">
              <button onClick={() => setStep("review")} className="rounded-lg border border-border px-4 py-2 text-sm text-muted-foreground hover:text-foreground">
                Back
              </button>
              <button
                onClick={handleStartUpdate}
                disabled={!fieldMappings.some((m) => m.csvColumn && m.sfField)}
                className="rounded-lg bg-primary px-6 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
              >
                Update {jobStatus?.matched.toLocaleString()} Records
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Step 6: Updating Progress */}
      {step === "updating" && (
        <div className="rounded-xl border border-border bg-card p-8 text-center space-y-4">
          <div className="mx-auto h-10 w-10 animate-spin rounded-full border-3 border-primary border-t-transparent" />
          <h2 className="text-lg font-semibold text-foreground">Updating Records...</h2>
          <div className="mx-auto max-w-md">
            <div className="h-3 w-full overflow-hidden rounded-full bg-muted">
              <div
                className="h-full rounded-full bg-primary transition-all duration-500"
                style={{ width: `${jobStatus?.progress || 0}%` }}
              />
            </div>
            <p className="mt-2 text-sm text-muted-foreground">
              {jobStatus?.progress || 0}% — updating {jobStatus?.matched?.toLocaleString() || 0} records via Bulk API
            </p>
          </div>
        </div>
      )}

      {/* Step 7: Final Results */}
      {step === "results" && jobStatus && (
        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="rounded-lg border border-green-500/20 bg-green-500/5 p-4">
              <div className="text-2xl font-bold text-green-400">{jobStatus.updateSuccessCount.toLocaleString()}</div>
              <div className="text-xs text-muted-foreground">Successfully Updated</div>
            </div>
            <div className="rounded-lg border border-red-500/20 bg-red-500/5 p-4">
              <div className="text-2xl font-bold text-red-400">{jobStatus.updateFailedCount.toLocaleString()}</div>
              <div className="text-xs text-muted-foreground">Failed</div>
            </div>
          </div>

          {updateFailures.length > 0 && (
            <div className="rounded-lg border border-border bg-card p-4">
              <p className="mb-2 text-sm font-medium text-foreground">Failed Records</p>
              <div className="max-h-48 overflow-auto">
                <table className="w-full text-xs">
                  <thead>
                    <tr className="border-b border-border">
                      <th className="px-3 py-2 text-left text-muted-foreground">Record ID</th>
                      <th className="px-3 py-2 text-left text-muted-foreground">Error</th>
                    </tr>
                  </thead>
                  <tbody>
                    {updateFailures.map((f, i) => (
                      <tr key={i} className="border-b border-border/50">
                        <td className="px-3 py-1.5 font-mono text-foreground">{f.id}</td>
                        <td className="px-3 py-1.5 text-destructive">{f.error}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}

          <button
            onClick={reset}
            className="rounded-lg bg-primary px-6 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90"
          >
            Start New Bulk Match
          </button>
        </div>
      )}
    </div>
  );
}
