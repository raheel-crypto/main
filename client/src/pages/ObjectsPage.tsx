import { ObjectList } from "../components/objects/ObjectList";
import { useObjects } from "../hooks/useObjects";

export function ObjectsPage() {
  const { data: objects, isLoading } = useObjects();

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground">Objects</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Browse and analyze Salesforce objects
        </p>
      </div>
      <ObjectList objects={objects} isLoading={isLoading} />
    </div>
  );
}
