import { useState, useEffect, useCallback } from "react";
import {
  api,
  SFObject,
  SFObjectDetail,
  ObjectAutomations,
} from "../lib/api";

export function useObjects(filter?: string) {
  const [data, setData] = useState<SFObject[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setIsLoading(true);
    api
      .getObjects(filter)
      .then(setData)
      .catch((err) => setError(err.message))
      .finally(() => setIsLoading(false));
  }, [filter]);

  return { data, isLoading, error };
}

export function useObjectDetail(name: string | undefined) {
  const [data, setData] = useState<SFObjectDetail | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!name) return;
    setIsLoading(true);
    setError(null);
    api
      .getObject(name)
      .then(setData)
      .catch((err) => setError(err.message))
      .finally(() => setIsLoading(false));
  }, [name]);

  return { data, isLoading, error };
}

export function useObjectAutomations(name: string | undefined) {
  const [data, setData] = useState<ObjectAutomations | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(() => {
    if (!name) return;
    setIsLoading(true);
    api
      .getObjectAutomations(name)
      .then(setData)
      .catch((err) => setError(err.message))
      .finally(() => setIsLoading(false));
  }, [name]);

  useEffect(() => {
    load();
  }, [load]);

  return { data, isLoading, error };
}
