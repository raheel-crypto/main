import { useState } from 'react';
import { Link } from 'react-router';
import { searchAccounts } from '../api/account/accountSearchService';
import { fieldValue } from '../features/object-search/utils/fieldUtils';
import { Skeleton } from '../components/ui/skeleton';

type AccountNode = any;

export default function AccountSearch() {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<AccountNode[]>([]);
  const [loading, setLoading] = useState(false);
  const [searched, setSearched] = useState(false);

  async function handleSearch(e: React.FormEvent) {
    e.preventDefault();
    const q = query.trim();
    if (!q) return;
    setLoading(true);
    setSearched(true);
    try {
      const where = {
        or: [
          { Name: { like: `%${q}%` } },
          { AccountNumber: { like: `%${q}%` } },
        ],
      };
      const res = await searchAccounts({ where, first: 50 });
      const nodes = (res?.edges ?? []).map((e: any) => e?.node).filter(Boolean);
      setResults(nodes);
    } catch {
      setResults([]);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="max-w-5xl mx-auto px-4 sm:px-6 py-10">
      <h1 className="text-2xl sm:text-3xl font-bold text-white mb-6">Search All Accounts</h1>

      <form onSubmit={handleSearch} className="flex gap-3 mb-8">
        <input
          type="text"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search by name or account number..."
          className="flex-1 bg-white/5 border border-white/10 rounded-xl px-4 py-2.5 text-sm text-white placeholder:text-slate-500 focus:outline-none focus:ring-2 focus:ring-white/20 backdrop-blur-sm"
        />
        <button
          type="submit"
          disabled={loading || !query.trim()}
          className="px-5 py-2.5 rounded-xl bg-white text-slate-950 text-sm font-medium hover:bg-white/90 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
        >
          Search
        </button>
      </form>

      {loading ? (
        <div className="space-y-3">
          {Array.from({ length: 5 }).map((_, i) => (
            <Skeleton key={i} className="h-16 rounded-xl bg-white/5" />
          ))}
        </div>
      ) : searched ? (
        results.length === 0 ? (
          <p className="text-slate-500 text-center py-12">No accounts found for "{query}".</p>
        ) : (
          <div className="divide-y divide-white/8 rounded-xl border border-white/10 overflow-hidden">
            {results.map((a: AccountNode, i: number) => {
              const name = fieldValue(a?.Name) ?? '—';
              const accountNumber = fieldValue(a?.AccountNumber);
              const status = fieldValue(a?.Account_Status__c);
              const owner = fieldValue(a?.Owner?.Name);
              const arr = a?.ARR__c?.displayValue ?? fieldValue(a?.AnnualRevenue);
              return (
                <Link
                  key={a?.Id ?? i}
                  to={`/accounts/${a?.Id}`}
                  className="flex items-center justify-between gap-4 px-5 py-4 bg-white/3 hover:bg-white/8 transition-colors"
                >
                  <div className="min-w-0">
                    <div className="text-white font-medium text-sm truncate">{name}</div>
                    <div className="text-slate-500 text-xs mt-0.5">
                      {[accountNumber ? `#${accountNumber}` : null, owner]
                        .filter(Boolean)
                        .join(' · ')}
                    </div>
                  </div>
                  <div className="flex items-center gap-3 flex-shrink-0">
                    {arr && <span className="text-white/80 text-sm font-medium">{arr}</span>}
                    {status && (
                      <span className="px-2.5 py-0.5 rounded-full text-xs font-medium bg-white/10 text-slate-300 ring-1 ring-white/15">
                        {status}
                      </span>
                    )}
                  </div>
                </Link>
              );
            })}
          </div>
        )
      ) : (
        <p className="text-slate-600 text-center py-12">Enter a search term above.</p>
      )}
    </div>
  );
}
