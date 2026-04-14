import { useState, useEffect } from "react";
import { api, AuthStatus } from "../lib/api";

export function useSalesforceAuth() {
  const [data, setData] = useState<AuthStatus | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api
      .getAuthStatus()
      .then(setData)
      .catch((err) => setError(err.message))
      .finally(() => setIsLoading(false));
  }, []);

  const logout = async () => {
    await api.logout();
    setData({ authenticated: false });
  };

  return { data, isLoading, error, logout };
}
