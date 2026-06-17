import { routes } from './routes';
import type { RouteObject } from 'react-router';

type FlatRoute = RouteObject & { fullPath: string };

function flattenRoutes(
  routeList: RouteObject[],
  parentPath = '',
): FlatRoute[] {
  const result: FlatRoute[] = [];
  for (const route of routeList) {
    const segment = route.path ?? (route.index ? '' : undefined);
    const fullPath =
      segment !== undefined
        ? `${parentPath}/${segment}`.replace(/\/+/g, '/').replace(/\/$/, '') || '/'
        : parentPath;

    result.push({ ...route, fullPath });

    if (route.children?.length) {
      result.push(...flattenRoutes(route.children, fullPath === '/' ? '' : fullPath));
    }
  }
  return result;
}

export function getAllRoutes(): FlatRoute[] {
  return flattenRoutes(routes);
}
