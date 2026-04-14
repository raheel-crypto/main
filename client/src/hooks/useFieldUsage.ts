import { useState } from "react";
import { api, FieldUsageTree } from "../lib/api";

export function useFieldUsage() {
  const [data, setData] = useState<FieldUsageTree | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const search = async (object: string, field: string) => {
    setIsLoading(true);
    setError(null);
    setData(null);
    try {
      const result = await api.getFieldUsage(object, field);
      setData(result);
    } catch (err: any) {
      setError(err.message);
    } finally {
      setIsLoading(false);
    }
  };

  return { data, isLoading, error, search };
}
