import { Outlet, NavLink, useNavigate } from 'react-router';
import { routes } from './routes';

const navItems = routes[0]?.children
  ?.filter((r: any) => r.handle?.showInNavigation)
  .map((r: any) => ({
    path: r.index ? '/' : `/${r.path}`,
    label: r.handle.label as string,
  })) ?? [];

export default function AppLayout() {
  const navigate = useNavigate();

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-950 via-slate-900 to-slate-950">
      <header className="sticky top-0 z-50 border-b border-white/8 bg-slate-950/80 backdrop-blur-xl">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 h-14 flex items-center justify-between gap-6">
          <button
            onClick={() => navigate('/')}
            className="text-white font-semibold text-sm tracking-wide hover:text-white/80 transition-colors"
          >
            Console
          </button>
          <nav className="flex items-center gap-1">
            {navItems.map((item) => (
              <NavLink
                key={item.path}
                to={item.path}
                end={item.path === '/'}
                className={({ isActive }) =>
                  `px-3 py-1.5 rounded-lg text-sm font-medium transition-colors ${
                    isActive
                      ? 'bg-white/15 text-white'
                      : 'text-slate-400 hover:text-white hover:bg-white/8'
                  }`
                }
              >
                {item.label}
              </NavLink>
            ))}
          </nav>
        </div>
      </header>
      <main>
        <Outlet />
      </main>
    </div>
  );
}
