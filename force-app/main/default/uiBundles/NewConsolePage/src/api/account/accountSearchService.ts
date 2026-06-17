import { createDataSDK } from '@salesforce/sdk-data';
import SEARCH_ACCOUNTS from './query/searchAccounts.graphql?raw';

export interface SearchAccountsOptions {
  where?: Record<string, any>;
  first?: number;
  after?: string;
  orderBy?: Record<string, any>;
}

export async function searchAccounts(options: SearchAccountsOptions = {}) {
  const sdk = await createDataSDK();
  const res = await sdk.graphql?.(SEARCH_ACCOUNTS, {
    first: options.first ?? 50,
    after: options.after,
    where: options.where,
    orderBy: options.orderBy,
  });
  return (res as any)?.data?.uiapi?.query?.Account ?? null;
}
