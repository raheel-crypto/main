import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { api } from "../lib/api";

interface OrgStats {
  objects: number;
  customObjects: number;
  flows: number;
  apexClasses: number;
}

export function DashboardPage() {
  const [stats, setStats] = useState<OrgStats | null>(null);

  useEffect(() => {
    Promise.all([api.getObjects(), api.getFlows(), api.getApexClasses()])
      .then(([objects, flows, apex]) => {
        setStats({
          objects: objects.length,
          customObjects: objects.filter((o) => o.custom).length,
          flows: flows.length,
          apexClasses: apex.length,
        });
      })
      .catch(console.error);
  }, []);

  const features = [
    {
      title: "Object Explorer",
      description: "Browse and analyze Salesforce objects, fields, and relationships",
      path: "/objects",
      icon: (
        <svg className="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
          <ellipse cx="12" cy="5" rx="9" ry="3" />
          <path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5" />
          <path d="M3 12c0 1.66 4 3 9 3s9-1.34 9-3" />
        </svg>
      ),
      color: "text-blue-400 bg-blue-500/10",
    },
    {
      title: "Field Usage",
      description: "Trace where any field is used across layouts, flows, apex, and more",
      path: "/fields",
      icon: (
        <svg className="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
          <line x1="6" y1="3" x2="6" y2="15" />
          <circle cx="18" cy="6" r="3" />
          <circle cx="6" cy="18" r="3" />
          <path d="M18 9a9 9 0 0 1-9 9" />
        </svg>
      ),
      color: "text-purple-400 bg-purple-500/10",
    },
    {
      title: "Flow Analyzer",
      description: "Understand flows with AI-powered explanations and element breakdowns",
      path: "/flows",
      icon: (
        <svg className="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
          <rect x="3" y="3" width="6" height="6" rx="1" />
          <rect x="15" y="3" width="6" height="6" rx="1" />
          <rect x="9" y="15" width="6" height="6" rx="1" />
          <path d="M6 9v3h6m6-6v3H12m0 0v6" />
        </svg>
      ),
      color: "text-orange-400 bg-orange-500/10",
    },
    {
      title: "Apex Explorer",
      description: "Analyze Apex classes with AI explanations and dependency tracking",
      path: "/apex",
      icon: (
        <svg className="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
          <polyline points="16,18 22,12 16,6" />
          <polyline points="8,6 2,12 8,18" />
        </svg>
      ),
      color: "text-green-400 bg-green-500/10",
    },
  ];

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-bold text-foreground">Dashboard</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Your Salesforce org at a glance
        </p>
      </div>

      {/* Stats */}
      {stats && (
        <div className="grid grid-cols-4 gap-4">
          <StatCard
            label="Total Objects"
            value={stats.objects}
            sublabel={`${stats.customObjects} custom`}
          />
          <StatCard label="Flows" value={stats.flows} />
          <StatCard label="Apex Classes" value={stats.apexClasses} />
          <StatCard
            label="Custom Objects"
            value={stats.customObjects}
          />
        </div>
      )}

      {/* Feature cards */}
      <div className="grid grid-cols-2 gap-4">
        {features.map((feature) => (
          <Link
            key={feature.path}
            to={feature.path}
            className="group rounded-xl border border-border bg-card p-6 transition-all hover:border-primary/50 hover:shadow-lg hover:shadow-primary/5"
          >
            <div className="flex items-start gap-4">
              <div
                className={`flex h-12 w-12 items-center justify-center rounded-lg ${feature.color}`}
              >
                {feature.icon}
              </div>
              <div className="flex-1">
                <h3 className="text-sm font-semibold text-foreground group-hover:text-primary">
                  {feature.title}
                </h3>
                <p className="mt-1 text-xs text-muted-foreground">
                  {feature.description}
                </p>
              </div>
              <svg
                className="h-5 w-5 text-muted-foreground transition-transform group-hover:translate-x-1 group-hover:text-primary"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                strokeWidth={2}
              >
                <path d="M5 12h14M12 5l7 7-7 7" />
              </svg>
            </div>
          </Link>
        ))}
      </div>
    </div>
  );
}

function StatCard({
  label,
  value,
  sublabel,
}: {
  label: string;
  value: number;
  sublabel?: string;
}) {
  return (
    <div className="rounded-lg border border-border bg-card p-4">
      <div className="text-2xl font-bold text-foreground">{value}</div>
      <div className="text-xs text-muted-foreground">{label}</div>
      {sublabel && (
        <div className="mt-1 text-xs text-muted-foreground/70">
          {sublabel}
        </div>
      )}
    </div>
  );
}
