import { createClient } from "@/lib/supabase/server";
import { redirect } from "next/navigation";
import Link from "next/link";
import { Button } from "@/components/ui/button";
import { 
  Calendar, 
  ArrowRight, 
  CheckCircle2, 
  AlertTriangle,
  Target,
  TrendingUp 
} from "lucide-react";
import { getWeekStart, formatWeekRange } from "@/lib/date-utils";

export default async function DashboardPage() {
  const supabase = await createClient();
  const { data: { user: authUser } } = await supabase.auth.getUser();

  if (!authUser) {
    redirect("/auth/login");
  }

  // Get user profile
  const { data: profile } = await supabase
    .from("users")
    .select("*")
    .eq("auth_id", authUser.id)
    .single();

  // Get current week start
  const weekStart = getWeekStart(new Date());
  const weekRange = formatWeekRange(weekStart);

  // Get current week's review
  const { data: currentWeek } = await supabase
    .from("review_weeks")
    .select(`
      *,
      commitments:weekly_commitments(*)
    `)
    .eq("rep_id", profile?.id)
    .eq("week_start", weekStart.toISOString().split("T")[0])
    .single();

  // Calculate commitment stats
  const commitments = currentWeek?.commitments || [];
  const totalCommitments = commitments.length;
  const metCommitments = commitments.filter((c: { status: string }) => c.status === "met" || c.status === "exceeded").length;
  const missedCommitments = commitments.filter((c: { status: string }) => c.status === "missed").length;

  // Get recent activities count
  const weekAgo = new Date();
  weekAgo.setDate(weekAgo.getDate() - 7);
  
  const { count: activityCount } = await supabase
    .from("activities")
    .select("*", { count: "exact", head: true })
    .eq("rep_id", profile?.id)
    .gte("occurred_at", weekAgo.toISOString());

  return (
    <div className="space-y-8">
      {/* Welcome */}
      <div>
        <h1 className="text-2xl font-bold text-foreground">
          Welcome back, {profile?.full_name?.split(" ")[0] || "there"}
        </h1>
        <p className="text-muted-foreground mt-1">
          Here&apos;s your pipeline review status for {weekRange}
        </p>
      </div>

      {/* Current Week Card */}
      <div className="bg-card border border-border rounded-xl p-6">
        <div className="flex items-start justify-between mb-6">
          <div>
            <div className="flex items-center gap-2 text-sm text-muted-foreground mb-1">
              <Calendar className="w-4 h-4" />
              {weekRange}
            </div>
            <h2 className="text-lg font-semibold text-foreground">This Week&apos;s Review</h2>
          </div>
          <div className={`px-2.5 py-1 rounded-full text-xs font-medium ${
            currentWeek?.status === "reviewed"
              ? "bg-success/10 text-success"
              : currentWeek?.status === "submitted"
              ? "bg-primary/10 text-primary"
              : "bg-muted text-muted-foreground"
          }`}>
            {currentWeek?.status === "reviewed" 
              ? "Reviewed" 
              : currentWeek?.status === "submitted"
              ? "Submitted"
              : currentWeek
              ? "Draft"
              : "Not started"}
          </div>
        </div>

        {currentWeek ? (
          <>
            {/* Stats Grid */}
            <div className="grid grid-cols-3 gap-4 mb-6">
              <div className="bg-background rounded-lg p-4 border border-border">
                <div className="flex items-center gap-2 text-sm text-muted-foreground mb-1">
                  <Target className="w-4 h-4" />
                  Commitments
                </div>
                <div className="text-2xl font-bold text-foreground">{totalCommitments}</div>
              </div>
              <div className="bg-background rounded-lg p-4 border border-border">
                <div className="flex items-center gap-2 text-sm text-success mb-1">
                  <CheckCircle2 className="w-4 h-4" />
                  Met/Exceeded
                </div>
                <div className="text-2xl font-bold text-success">{metCommitments}</div>
              </div>
              <div className="bg-background rounded-lg p-4 border border-border">
                <div className="flex items-center gap-2 text-sm text-destructive mb-1">
                  <AlertTriangle className="w-4 h-4" />
                  Missed
                </div>
                <div className="text-2xl font-bold text-destructive">{missedCommitments}</div>
              </div>
            </div>

            <Link href="/dashboard/week">
              <Button className="gap-2">
                {currentWeek.status === "draft" ? "Continue planning" : "View details"}
                <ArrowRight className="w-4 h-4" />
              </Button>
            </Link>
          </>
        ) : (
          <div className="text-center py-8">
            <Target className="w-10 h-10 text-muted-foreground mx-auto mb-3" />
            <p className="text-muted-foreground mb-4">
              You haven&apos;t started planning this week yet.
            </p>
            <Link href="/dashboard/week">
              <Button className="gap-2">
                Start weekly planning
                <ArrowRight className="w-4 h-4" />
              </Button>
            </Link>
          </div>
        )}
      </div>

      {/* Activity Summary */}
      <div className="bg-card border border-border rounded-xl p-6">
        <div className="flex items-center gap-2 mb-4">
          <TrendingUp className="w-5 h-5 text-primary" />
          <h2 className="text-lg font-semibold text-foreground">Activity This Week</h2>
        </div>
        <div className="text-3xl font-bold text-foreground mb-1">
          {activityCount || 0}
        </div>
        <p className="text-sm text-muted-foreground">
          Total activities tracked from all connected sources
        </p>
        <Link href="/dashboard/week#activities">
          <Button variant="outline" size="sm" className="mt-4 gap-2">
            View activity timeline
            <ArrowRight className="w-4 h-4" />
          </Button>
        </Link>
      </div>
    </div>
  );
}
