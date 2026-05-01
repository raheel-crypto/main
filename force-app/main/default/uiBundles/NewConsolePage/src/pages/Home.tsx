// @ts-ignore - Salesforce module resolved at LWR runtime
import sfUserId from "@salesforce/user/Id";
import { useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { createDataSDK } from "@salesforce/sdk-data";
import { Button } from "../components/ui/button";
import { Card, CardContent } from "../components/ui/card";
import { Skeleton } from "../components/ui/skeleton";

const USER_QUERY = `
  query CurrentUser($userId: ID!) {
    uiapi {
      query {
        User(where: { Id: { eq: $userId } }, first: 1) {
          edges {
            node {
              FirstName @optional { value }
              Name @optional { value }
            }
          }
        }
      }
    }
  }
`;

const ACCOUNT_COUNT_QUERY = `
  query MyAccountCount($userId: ID!) {
    uiapi {
      query {
        Account(where: { OwnerId: { eq: $userId } }, first: 1) {
          totalCount
        }
      }
    }
  }
`;

const OPEN_OPPS_QUERY = `
  query MyOpenOpps($userId: ID!) {
    uiapi {
      query {
        Opportunity(where: { OwnerId: { eq: $userId }, IsClosed: { eq: false } }, first: 1) {
          totalCount
        }
      }
    }
  }
`;

function timeGreeting() {
  const h = new Date().getHours();
  if (h < 12) return "Good morning";
  if (h < 17) return "Good afternoon";
  return "Good evening";
}

export default function Home() {
  const navigate = useNavigate();
  const [firstName, setFirstName] = useState("");
  const [accountCount, setAccountCount] = useState<number | null>(null);
  const [oppCount, setOppCount] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!sfUserId) {
      setLoading(false);
      return;
    }
    (async () => {
      try {
        const sdk = await createDataSDK();
        const [userRes, accountRes, oppRes] = await Promise.all([
          sdk.graphql?.(USER_QUERY, { userId: sfUserId }),
          sdk.graphql?.(ACCOUNT_COUNT_QUERY, { userId: sfUserId }),
          sdk.graphql?.(OPEN_OPPS_QUERY, { userId: sfUserId }),
        ]);
        const node = (userRes as any)?.data?.uiapi?.query?.User?.edges?.[0]?.node;
        const fullName: string = node?.FirstName?.value ?? node?.Name?.value ?? "";
        setFirstName(fullName.split(" ")[0]);
        setAccountCount((accountRes as any)?.data?.uiapi?.query?.Account?.totalCount ?? null);
        setOppCount((oppRes as any)?.data?.uiapi?.query?.Opportunity?.totalCount ?? null);
      } catch {
        // non-fatal — page still renders without stats
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  return (
    <div className="max-w-3xl mx-auto px-4 sm:px-6 py-16">
      <div className="mb-10">
        {loading ? (
          <Skeleton className="h-9 w-72 mb-2" />
        ) : (
          <h1 className="text-3xl font-bold mb-2">
            {timeGreeting()}{firstName ? `, ${firstName}` : ""}
          </h1>
        )}
        <p className="text-muted-foreground">Here's a snapshot of your accounts and pipeline.</p>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-10">
        <Card
          className="cursor-pointer hover:shadow-md transition-shadow"
          onClick={() => navigate("/accounts")}
        >
          <CardContent className="pt-6">
            <div className="text-sm text-muted-foreground mb-1">My Accounts</div>
            {loading ? (
              <Skeleton className="h-8 w-12" />
            ) : (
              <div className="text-2xl font-semibold">{accountCount ?? "—"}</div>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardContent className="pt-6">
            <div className="text-sm text-muted-foreground mb-1">Open Opportunities</div>
            {loading ? (
              <Skeleton className="h-8 w-12" />
            ) : (
              <div className="text-2xl font-semibold">{oppCount ?? "—"}</div>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardContent className="pt-6">
            <div className="text-sm text-muted-foreground mb-1">Deals Closing Soon</div>
            <div className="text-2xl font-semibold text-muted-foreground">—</div>
          </CardContent>
        </Card>
      </div>

      <div className="flex gap-3">
        <Button size="lg" onClick={() => navigate("/accounts")}>
          My Accounts
        </Button>
        <Button size="lg" variant="outline" onClick={() => navigate("/accounts-search")}>
          Search All Accounts
        </Button>
      </div>
    </div>
  );
}
