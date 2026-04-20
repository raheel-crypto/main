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
import { UsersPage } from "./pages/UsersPage";
import { UserDetailPage } from "./pages/UserDetailPage";
import { ProfileDetailPage } from "./pages/ProfileDetailPage";
import { PermissionSetDetailPage } from "./pages/PermissionSetDetailPage";
import { CleanupPage } from "./pages/CleanupPage";
import { ArchitectPage } from "./pages/ArchitectPage";
import { SFMcpPage } from "./pages/SFMcpPage";
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
        <Route path="/users" element={<UsersPage />} />
        <Route path="/users/:id" element={<UserDetailPage />} />
        <Route path="/users/profiles/:id" element={<ProfileDetailPage />} />
        <Route path="/users/permission-sets/:id" element={<PermissionSetDetailPage />} />
        <Route path="/cleanup" element={<CleanupPage />} />
        <Route path="/architect" element={<ArchitectPage />} />
        <Route path="/sf-mcp" element={<SFMcpPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </AppLayout>
  );
}
