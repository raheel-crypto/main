import { useState } from "react";
import { cn } from "../../lib/utils";
import { FieldsTable } from "./FieldsTable";
import { RelationshipMap } from "./RelationshipMap";
import type { SFObjectDetail, ObjectAutomations } from "../../lib/api";

interface ObjectOverviewProps {
  detail: SFObjectDetail;
  automations: ObjectAutomations | null;
}

const tabs = ["Fields", "Relationships", "Automations"] as const;

export function ObjectOverview({ detail, automations }: ObjectOverviewProps) {
  const [activeTab, setActiveTab] = useState<(typeof tabs)[number]>("Fields");

  return (
    <div className="space-y-6">
      {/* Summary cards */}
      <div className="grid grid-cols-4 gap-4">
        <StatCard label="Fields" value={detail.fields.length} />
        <StatCard
          label="Custom Fields"
          value={detail.fields.filter((f) => f.custom).length}
        />
        <StatCard
          label="Relationships"
          value={detail.childRelationships.length}
        />
        <StatCard
          label="Record Types"
          value={detail.recordTypes.filter((rt) => rt.active).length}
        />
      </div>

      {/* Tabs */}
      <div className="border-b border-border">
        <div className="flex gap-0">
          {tabs.map((tab) => (
            <button
              key={tab}
              onClick={() => setActiveTab(tab)}
              className={cn(
                "border-b-2 px-4 py-2 text-sm font-medium transition-colors",
                activeTab === tab
                  ? "border-primary text-foreground"
                  : "border-transparent text-muted-foreground hover:text-foreground"
              )}
            >
              {tab}
            </button>
          ))}
        </div>
      </div>

      {/* Tab content */}
      {activeTab === "Fields" && <FieldsTable fields={detail.fields} objectName={detail.name} />}
      {activeTab === "Relationships" && (
        <RelationshipMap
          relationships={detail.childRelationships}
          fields={detail.fields}
        />
      )}
      {activeTab === "Automations" && (
        <AutomationsTab automations={automations} />
      )}
    </div>
  );
}

function StatCard({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded-lg border border-border bg-card p-4">
      <div className="text-2xl font-bold text-foreground">{value}</div>
      <div className="text-xs text-muted-foreground">{label}</div>
    </div>
  );
}

function AutomationsTab({
  automations,
}: {
  automations: ObjectAutomations | null;
}) {
  if (!automations) {
    return (
      <div className="py-8 text-center text-sm text-muted-foreground">
        Loading automations...
      </div>
    );
  }

  const hasAny =
    automations.flows.length > 0 ||
    automations.validationRules.length > 0 ||
    automations.triggers.length > 0;

  if (!hasAny) {
    return (
      <div className="py-8 text-center text-sm text-muted-foreground">
        No automations found for this object.
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {automations.flows.length > 0 && (
        <AutomationSection
          title="Flows"
          items={automations.flows.map((f) => ({
            name: f.name,
            badge: f.type,
            status: f.status,
          }))}
        />
      )}
      {automations.validationRules.length > 0 && (
        <AutomationSection
          title="Validation Rules"
          items={automations.validationRules.map((v) => ({
            name: v.name,
            badge: "Validation",
            status: v.active ? "Active" : "Inactive",
          }))}
        />
      )}
      {automations.triggers.length > 0 && (
        <AutomationSection
          title="Apex Triggers"
          items={automations.triggers.map((t) => ({
            name: t.name,
            badge: "Trigger",
            status: t.status,
          }))}
        />
      )}
    </div>
  );
}

function AutomationSection({
  title,
  items,
}: {
  title: string;
  items: { name: string; badge: string; status: string }[];
}) {
  return (
    <div>
      <h3 className="mb-2 text-sm font-medium text-foreground">{title}</h3>
      <div className="space-y-1">
        {items.map((item) => (
          <div
            key={item.name}
            className="flex items-center justify-between rounded-lg border border-border px-4 py-2"
          >
            <div className="flex items-center gap-2">
              <span className="text-sm text-foreground">{item.name}</span>
              <span className="rounded bg-muted px-2 py-0.5 text-xs text-muted-foreground">
                {item.badge}
              </span>
            </div>
            <span
              className={cn(
                "rounded-full px-2 py-0.5 text-xs font-medium",
                item.status === "Active"
                  ? "bg-green-500/10 text-green-400"
                  : "bg-yellow-500/10 text-yellow-400"
              )}
            >
              {item.status}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}
