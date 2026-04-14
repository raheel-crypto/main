import { useSearchParams } from "react-router-dom";
import { FieldSearch } from "../components/fields/FieldSearch";
import { UsageTree } from "../components/fields/UsageTree";
import { useFieldUsage } from "../hooks/useFieldUsage";

export function FieldUsagePage() {
  const [searchParams] = useSearchParams();
  const initialObject = searchParams.get("object") || undefined;
  const initialField = searchParams.get("field") || undefined;

  const { data, isLoading, error, search } = useFieldUsage();

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground">Field Usage</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Find everywhere a field is used across your org
        </p>
      </div>

      <FieldSearch
        onSearch={search}
        initialObject={initialObject}
        initialField={initialField}
      />

      {isLoading && (
        <div className="flex items-center gap-2 py-8">
          <div className="h-4 w-4 animate-spin rounded-full border-2 border-primary border-t-transparent" />
          <span className="text-sm text-muted-foreground">
            Searching for field usage...
          </span>
        </div>
      )}

      {error && (
        <div className="rounded-lg border border-destructive/50 bg-destructive/5 p-4 text-sm text-destructive">
          {error}
        </div>
      )}

      {data && <UsageTree data={data} />}
    </div>
  );
}
