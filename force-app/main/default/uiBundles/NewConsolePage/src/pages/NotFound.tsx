import { Link } from 'react-router';

export default function NotFound() {
  return (
    <div className="flex flex-col items-center justify-center min-h-[60vh] gap-4 text-center px-4">
      <p className="text-6xl font-bold text-white/20">404</p>
      <p className="text-slate-400">Page not found.</p>
      <Link to="/" className="text-sm text-slate-400 underline hover:text-white transition-colors">
        Go home
      </Link>
    </div>
  );
}
