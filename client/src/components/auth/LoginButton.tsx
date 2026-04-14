export function LoginButton() {
  return (
    <div className="flex h-screen items-center justify-center bg-background">
      <div className="w-full max-w-md space-y-8 rounded-xl border border-border bg-card p-8 text-center">
        <div className="space-y-2">
          <div className="mx-auto flex h-16 w-16 items-center justify-center rounded-2xl bg-sf-blue">
            <svg
              className="h-9 w-9 text-white"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              strokeWidth={2}
            >
              <path d="M13 10V3L4 14h7v7l9-11h-7z" />
            </svg>
          </div>
          <h1 className="text-2xl font-bold text-foreground">
            Salesforce AI Visualizer
          </h1>
          <p className="text-sm text-muted-foreground">
            Connect your Salesforce org to visualize metadata, analyze
            dependencies, and get AI-powered insights.
          </p>
        </div>

        <div className="space-y-4">
          <a
            href="/auth/login"
            className="inline-flex w-full items-center justify-center gap-2 rounded-lg bg-sf-blue px-6 py-3 text-sm font-medium text-white transition-colors hover:bg-sf-blue/90"
          >
            <svg
              className="h-5 w-5"
              viewBox="0 0 24 24"
              fill="currentColor"
            >
              <path d="M16.9 14.6c-.3.9-1 1.6-1.9 2-.5.2-1.1.3-1.6.3-.6 0-1.1-.1-1.6-.3-.9-.4-1.6-1.1-1.9-2-.2-.5-.3-1.1-.3-1.6 0-.6.1-1.1.3-1.6.3-.9 1-1.6 1.9-2 .5-.2 1.1-.3 1.6-.3.6 0 1.1.1 1.6.3.9.4 1.6 1.1 1.9 2 .2.5.3 1.1.3 1.6 0 .6-.1 1.1-.3 1.6z" />
            </svg>
            Connect to Salesforce
          </a>

          <div className="space-y-2">
            <h3 className="text-xs font-medium uppercase tracking-wider text-muted-foreground">
              What you can do
            </h3>
            <div className="grid gap-2 text-left">
              {[
                "Visualize field usage across your entire org",
                "Get comprehensive object overviews",
                "Understand flows with AI-powered explanations",
                "Analyze Apex classes and their dependencies",
              ].map((item) => (
                <div
                  key={item}
                  className="flex items-start gap-2 text-xs text-muted-foreground"
                >
                  <svg
                    className="mt-0.5 h-3 w-3 shrink-0 text-sf-blue"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                    strokeWidth={3}
                  >
                    <polyline points="20,6 9,17 4,12" />
                  </svg>
                  {item}
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
