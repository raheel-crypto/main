import { ApexList } from "../components/apex/ApexList";
import { useApexClasses } from "../hooks/useApex";

export function ApexPage() {
  const { data: classes, isLoading } = useApexClasses();

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground">Apex Classes</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Browse and analyze Apex classes with AI
        </p>
      </div>
      <ApexList classes={classes} isLoading={isLoading} />
    </div>
  );
}
