import { useState, useEffect } from "react";
import { api, FlowSummary, FlowDetail, AIExplanation } from "../lib/api";

export function useFlows() {
  const [data, setData] = useState<FlowSummary[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api
      .getFlows()
      .then(setData)
      .catch((err) => setError(err.message))
      .finally(() => setIsLoading(false));
  }, []);

  return { data, isLoading, error };
}

export function useFlowDetail(id: string | undefined) {
  const [data, setData] = useState<FlowDetail | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!id) return;
    setIsLoading(true);
    setError(null);
    api
      .getFlow(id)
      .then(setData)
      .catch((err) => setError(err.message))
      .finally(() => setIsLoading(false));
  }, [id]);

  return { data, isLoading, error };
}

export function useFlowExplanation() {
  const [data, setData] = useState<AIExplanation | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const explain = async (id: string) => {
    setIsLoading(true);
    setError(null);
    setData(null);
    try {
      const result = await api.explainFlow(id);
      setData(result);
    } catch (err: any) {
      setError(err.message);
    } finally {
      setIsLoading(false);
    }
  };

  return { data, isLoading, error, explain };
}
