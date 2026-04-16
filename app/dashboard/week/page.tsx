import { createClient } from "@/lib/supabase/server";
import { redirect } from "next/navigation";
import { getWeekStart, formatWeekRange } from "@/lib/date-utils";
import { WeeklyPlanningView } from "@/components/dashboard/weekly-planning-view";

export default async function WeekPage() {
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

  if (!profile) {
    redirect("/auth/login");
  }

  // Get current week start
  const weekStart = getWeekStart(new Date());
  const weekStartStr = weekStart.toISOString().split("T")[0];
  const weekRange = formatWeekRange(weekStart);

  // Get or create current week's review
  let { data: reviewWeek } = await supabase
    .from("review_weeks")
    .select(`
      *,
      focus_accounts:weekly_focus_accounts(
        *,
        account:accounts(*)
      ),
      commitments:weekly_commitments(
        *,
        deal:deals(*),
        account:accounts(*)
      ),
      comments:review_comments(
        *,
        user:users(*)
      )
    `)
    .eq("rep_id", profile.id)
    .eq("week_start", weekStartStr)
    .single();

  // If no review week exists, create one
  if (!reviewWeek) {
    const { data: newWeek, error } = await supabase
      .from("review_weeks")
      .insert({
        rep_id: profile.id,
        week_start: weekStartStr,
        status: "draft",
      })
      .select()
      .single();

    if (!error && newWeek) {
      reviewWeek = { 
        ...newWeek, 
        focus_accounts: [], 
        commitments: [], 
        comments: [] 
      };
    }
  }

  // Get all accounts for selection
  const { data: accounts } = await supabase
    .from("accounts")
    .select("*")
    .order("name");

  // Get all deals for selection
  const { data: deals } = await supabase
    .from("deals")
    .select(`
      *,
      account:accounts(*)
    `)
    .eq("owner_id", profile.id)
    .order("name");

  // Get activities for this week
  const weekEnd = new Date(weekStart);
  weekEnd.setDate(weekEnd.getDate() + 7);

  const { data: activities } = await supabase
    .from("activities")
    .select(`
      *,
      account:accounts(*),
      deal:deals(*)
    `)
    .eq("rep_id", profile.id)
    .gte("occurred_at", weekStart.toISOString())
    .lt("occurred_at", weekEnd.toISOString())
    .order("occurred_at", { ascending: false });

  return (
    <WeeklyPlanningView
      reviewWeek={reviewWeek}
      weekRange={weekRange}
      accounts={accounts || []}
      deals={deals || []}
      activities={activities || []}
      userId={profile.id}
    />
  );
}
