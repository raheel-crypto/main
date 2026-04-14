import { useState, useEffect } from "react";
import { api, ApexSummary, ApexDetail, AIExplanation } from "../lib/api";

export function useApexClasses() {
  const [data, setData] = useState<ApexSummary[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api
      .getApexClasses()
      .then(setData)
      .catch((err) => setError(err.message))
      .finally(() => setIsLoading(false));
  }, []);

  return { data, isLoading, error };
}

export function useApexDetail(id: string | undefined) {
  const [data, setData] = useState<ApexDetail | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!id) return;
    setIsLoading(true);
    setError(null);
    api
      .getApexClass(id)
      .then(setData)
      .catch((err) => setError(err.message))
      .finally(() => setIsLoading(false));
  }, [id]);

  return { data, isLoading, error };
}

export function useApexExplanation() {
  const [data, setData] = useState<AIExplanation | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const explain = async (id: string) => {
    setIsLoading(true);
    setError(null);
    setData(null);
    try {
      const result = await api.explainApex(id);
      setData(result);
    } catch (err: any) {
      setError(err.message);
    } finally {
      setIsLoading(false);
    }
  };

  return { data, isLoading, error, explain };
}
