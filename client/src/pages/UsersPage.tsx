import { UserList } from "../components/users/UserList";
import { useUsers } from "../hooks/useUsers";

export function UsersPage() {
  const { data: users, isLoading } = useUsers();

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground">Users</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Active users, their profiles, licenses, and login activity
        </p>
      </div>
      <UserList users={users} isLoading={isLoading} />
    </div>
  );
}
