import { Request, Response, NextFunction } from "express";

export function requireAuth(req: Request, res: Response, next: NextFunction) {
  if (!req.session.sf?.accessToken) {
    res.status(401).json({ message: "Not authenticated. Please connect to Salesforce." });
    return;
  }
  next();
}
