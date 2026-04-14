import { useState, useEffect } from "react";
import {
  api,
  UserSummary,
  UserDetail,
  PermissionSetSummary,
  PermissionSetDetail,
  RecordCount,
  ProfileSummary,
  ProfilePermissions,
} from "../lib/api";

export function useUsers() {
  const [data, setData] = useState<UserSummary[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api
      .getUsers()
      .then(setData)
      .catch((err) => setError(err.message))
      .finally(() => setIsLoading(false));
  }, []);

  return { data, isLoading, error };
}

export function useUserDetail(id: string | undefined) {
  const [data, setData] = useState<UserDetail | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!id) return;
    setIsLoading(true);
    setError(null);
    api
      .getUser(id)
      .then(setData)
      .catch((err) => setError(err.message))
      .finally(() => setIsLoading(false));
  }, [id]);

  return { data, isLoading, error };
}

export function useUserRecords(id: string | undefined) {
  const [data, setData] = useState<RecordCount[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = () => {
    if (!id) return;
    setIsLoading(true);
    setError(null);
    api
      .getUserRecords(id)
      .then(setData)
      .catch((err) => setError(err.message))
      .finally(() => setIsLoading(false));
  };

  return { data, isLoading, error, load };
}

export function useProfiles() {
  const [data, setData] = useState<ProfileSummary[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api
      .getProfiles()
      .then(setData)
      .catch((err) => setError(err.message))
      .finally(() => setIsLoading(false));
  }, []);

  return { data, isLoading, error };
}

export function useProfilePermissions(id: string | undefined) {
  const [data, setData] = useState<ProfilePermissions | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!id) return;
    setIsLoading(true);
    setError(null);
    api
      .getProfilePermissions(id)
      .then(setData)
      .catch((err) => setError(err.message))
      .finally(() => setIsLoading(false));
  }, [id]);

  return { data, isLoading, error };
}

export function usePermissionSets() {
  const [data, setData] = useState<PermissionSetSummary[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api
      .getPermissionSets()
      .then(setData)
      .catch((err) => setError(err.message))
      .finally(() => setIsLoading(false));
  }, []);

  return { data, isLoading, error };
}

export function usePermissionSetDetail(id: string | undefined) {
  const [data, setData] = useState<PermissionSetDetail | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!id) return;
    setIsLoading(true);
    setError(null);
    api
      .getPermissionSetDetail(id)
      .then(setData)
      .catch((err) => setError(err.message))
      .finally(() => setIsLoading(false));
  }, [id]);

  return { data, isLoading, error };
}
