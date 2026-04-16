import Link from "next/link";
import { Button } from "@/components/ui/button";
import { 
  BarChart3, 
  Target, 
  Users, 
  TrendingUp, 
  CheckCircle2,
  ArrowRight 
} from "lucide-react";

export default function HomePage() {
  return (
    <div className="min-h-screen bg-background">
      {/* Header */}
      <header className="border-b border-border">
        <div className="max-w-6xl mx-auto px-4 py-4 flex items-center justify-between">
          <div className="flex items-center gap-2">
            <div className="w-8 h-8 rounded-lg bg-primary flex items-center justify-center">
              <BarChart3 className="w-4 h-4 text-primary-foreground" />
            </div>
            <span className="font-semibold text-lg">Pipeline Review</span>
          </div>
          <div className="flex items-center gap-3">
            <Link href="/auth/login">
              <Button variant="ghost">Sign in</Button>
            </Link>
            <Link href="/auth/sign-up">
              <Button>Get started</Button>
            </Link>
          </div>
        </div>
      </header>

      {/* Hero */}
      <section className="max-w-6xl mx-auto px-4 py-20 text-center">
        <div className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-primary/10 text-primary text-sm font-medium mb-6">
          <Target className="w-4 h-4" />
          Weekly accountability for sales teams
        </div>
        <h1 className="text-4xl md:text-5xl font-bold text-foreground max-w-3xl mx-auto leading-tight text-balance">
          Turn pipeline reviews into 
          <span className="text-primary"> commitment-driven</span> coaching sessions
        </h1>
        <p className="text-lg text-muted-foreground max-w-2xl mx-auto mt-6 text-pretty">
          Reps select focus accounts, make weekly commitments, and track actual activity against goals. 
          Managers get red flag alerts when commitments are missed.
        </p>
        <div className="flex items-center justify-center gap-4 mt-8">
          <Link href="/auth/sign-up">
            <Button size="lg" className="gap-2">
              Start tracking commitments
              <ArrowRight className="w-4 h-4" />
            </Button>
          </Link>
        </div>
      </section>

      {/* Features */}
      <section className="max-w-6xl mx-auto px-4 py-16">
        <div className="grid md:grid-cols-3 gap-6">
          <div className="bg-card border border-border rounded-xl p-6">
            <div className="w-10 h-10 rounded-lg bg-chart-1/10 flex items-center justify-center mb-4">
              <Target className="w-5 h-5 text-chart-1" />
            </div>
            <h3 className="font-semibold text-foreground mb-2">Weekly Commitments</h3>
            <p className="text-sm text-muted-foreground">
              Reps commit to outbound targets, deal actions, and meeting goals. 
              Track progress with hard data from your tools.
            </p>
          </div>

          <div className="bg-card border border-border rounded-xl p-6">
            <div className="w-10 h-10 rounded-lg bg-chart-2/10 flex items-center justify-center mb-4">
              <TrendingUp className="w-5 h-5 text-chart-2" />
            </div>
            <h3 className="font-semibold text-foreground mb-2">Activity Timeline</h3>
            <p className="text-sm text-muted-foreground">
              Pull activity from Gong, Nektar, Salesforce, and Apollo. 
              See exactly how reps spent their time.
            </p>
          </div>

          <div className="bg-card border border-border rounded-xl p-6">
            <div className="w-10 h-10 rounded-lg bg-destructive/10 flex items-center justify-center mb-4">
              <Users className="w-5 h-5 text-destructive" />
            </div>
            <h3 className="font-semibold text-foreground mb-2">Manager Red Flags</h3>
            <p className="text-sm text-muted-foreground">
              Dashboard alerts when reps miss commitments. 
              If they promised 20 contacts but did 5, you&apos;ll know.
            </p>
          </div>
        </div>
      </section>

      {/* How it works */}
      <section className="max-w-6xl mx-auto px-4 py-16 border-t border-border">
        <h2 className="text-2xl font-bold text-foreground text-center mb-12">
          How it works
        </h2>
        <div className="grid md:grid-cols-4 gap-8">
          {[
            { step: "1", title: "Select focus accounts", desc: "Reps pick their top accounts for the week" },
            { step: "2", title: "Make commitments", desc: "Set targets for outbound, meetings, and deals" },
            { step: "3", title: "Work gets synced", desc: "Activity flows in from your sales tools" },
            { step: "4", title: "Review together", desc: "Compare commitments vs. actual in 1:1s" },
          ].map((item) => (
            <div key={item.step} className="text-center">
              <div className="w-10 h-10 rounded-full bg-primary text-primary-foreground font-semibold flex items-center justify-center mx-auto mb-4">
                {item.step}
              </div>
              <h3 className="font-medium text-foreground mb-1">{item.title}</h3>
              <p className="text-sm text-muted-foreground">{item.desc}</p>
            </div>
          ))}
        </div>
      </section>

      {/* CTA */}
      <section className="max-w-6xl mx-auto px-4 py-16">
        <div className="bg-card border border-border rounded-2xl p-8 md:p-12 text-center">
          <CheckCircle2 className="w-12 h-12 text-success mx-auto mb-4" />
          <h2 className="text-2xl font-bold text-foreground mb-3">
            Ready to add accountability to your pipeline reviews?
          </h2>
          <p className="text-muted-foreground mb-6 max-w-xl mx-auto">
            Connect your tools, set up your team, and start tracking commitments in minutes.
          </p>
          <Link href="/auth/sign-up">
            <Button size="lg">Create your account</Button>
          </Link>
        </div>
      </section>

      {/* Footer */}
      <footer className="border-t border-border py-8">
        <div className="max-w-6xl mx-auto px-4 flex items-center justify-between text-sm text-muted-foreground">
          <div className="flex items-center gap-2">
            <BarChart3 className="w-4 h-4" />
            Pipeline Review
          </div>
          <div>Built for sales teams</div>
        </div>
      </footer>
    </div>
  );
}
