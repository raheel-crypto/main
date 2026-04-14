import { Routes, Route, Navigate } from "react-router-dom";
import { AppLayout } from "./components/layout/AppLayout";
import { DashboardPage } from "./pages/DashboardPage";
import { ObjectsPage } from "./pages/ObjectsPage";
import { ObjectDetailPage } from "./pages/ObjectDetailPage";
import { FieldUsagePage } from "./pages/FieldUsagePage";
import { FlowsPage } from "./pages/FlowsPage";
import { FlowDetailPage } from "./pages/FlowDetailPage";
import { ApexPage } from "./pages/ApexPage";
import { ApexDetailPage } from "./pages/ApexDetailPage";
import { useSalesforceAuth } from "./hooks/useSalesforceAuth";
import { LoginButton } from "./components/auth/LoginButton";

export default function App() {
  const { data: auth, isLoading } = useSalesforceAuth();

  if (isLoading) {
    return (
      <div className="flex h-screen items-center justify-center bg-background">
        <div className="text-muted-foreground">Loading...</div>
      </div>
    );
  }

  if (!auth?.authenticated) {
    return <LoginButton />;
  }

  return (
    <AppLayout user={auth.user!}>
      <Routes>
        <Route path="/" element={<DashboardPage />} />
        <Route path="/objects" element={<ObjectsPage />} />
        <Route path="/objects/:name" element={<ObjectDetailPage />} />
        <Route path="/fields" element={<FieldUsagePage />} />
        <Route path="/flows" element={<FlowsPage />} />
        <Route path="/flows/:id" element={<FlowDetailPage />} />
        <Route path="/apex" element={<ApexPage />} />
        <Route path="/apex/:id" element={<ApexDetailPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </AppLayout>
  );
}
