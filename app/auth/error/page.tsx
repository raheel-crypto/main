import Link from "next/link";
import { Button } from "@/components/ui/button";
import { AlertTriangle } from "lucide-react";

export default function AuthErrorPage() {
  return (
    <div className="min-h-screen bg-background flex items-center justify-center p-4">
      <div className="w-full max-w-md text-center">
        <div className="inline-flex items-center justify-center w-12 h-12 rounded-full bg-destructive/10 mb-4">
          <AlertTriangle className="w-6 h-6 text-destructive" />
        </div>
        <h1 className="text-2xl font-semibold text-foreground">Authentication Error</h1>
        <p className="text-muted-foreground mt-2">
          There was a problem signing you in. This could be due to an expired link or invalid credentials.
        </p>
        <div className="flex gap-3 justify-center mt-6">
          <Link href="/auth/login">
            <Button>Try again</Button>
          </Link>
          <Link href="/">
            <Button variant="outline">Go home</Button>
          </Link>
        </div>
      </div>
    </div>
  );
}
