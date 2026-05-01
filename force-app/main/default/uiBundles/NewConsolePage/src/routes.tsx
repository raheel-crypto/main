import type { RouteObject } from 'react-router';
import AppLayout from './appLayout';
import Home from './pages/Home';
import NotFound from './pages/NotFound';
import AccountSearch from './pages/AccountSearch';
import AccountTilesPage from './pages/AccountTilesPage';
import AccountDetailPage from './pages/AccountDetailPage';

export const routes: RouteObject[] = [
  {
    path: '/',
    element: <AppLayout />,
    children: [
      {
        index: true,
        element: <Home />,
        handle: { showInNavigation: true, label: 'Home' },
      },
      {
        path: 'accounts',
        element: <AccountTilesPage />,
        handle: { showInNavigation: true, label: 'My Accounts' },
      },
      {
        path: 'accounts/:recordId',
        element: <AccountDetailPage />,
      },
      {
        path: 'accounts-search',
        element: <AccountSearch />,
        handle: { showInNavigation: true, label: 'Search' },
      },
      {
        path: '*',
        element: <NotFound />,
      },
    ],
  },
];
