import express from "express";
import cors from "cors";
import session from "express-session";
import { config } from "./config.js";
import { requireAuth } from "./middleware/auth.js";
import authRoutes from "./routes/auth.js";
import objectRoutes from "./routes/objects.js";
import fieldRoutes from "./routes/fields.js";
import flowRoutes from "./routes/flows.js";
import apexRoutes from "./routes/apex.js";
import userRoutes from "./routes/users.js";
import cleanupRoutes from "./routes/cleanup.js";
import sfMcpRoutes from "./routes/sfmcp.js";
import bulkRoutes from "./routes/bulk.js";
import accountHierarchyRoutes from "./routes/accountHierarchy.js";

const app = express();

// Middleware
app.use(
  cors({
    origin: config.clientUrl,
    credentials: true,
  })
);
app.use(express.json({ limit: "50mb" }));
app.use(
  session({
    secret: config.sessionSecret,
    resave: false,
    saveUninitialized: false,
    cookie: {
      secure: false, // Set to true in production with HTTPS
      httpOnly: true,
      maxAge: 24 * 60 * 60 * 1000, // 24 hours
    },
  })
);

// Routes
app.use("/auth", authRoutes);
app.use("/api/objects", requireAuth, objectRoutes);
app.use("/api/fields", requireAuth, fieldRoutes);
app.use("/api/flows", requireAuth, flowRoutes);
app.use("/api/apex", requireAuth, apexRoutes);
app.use("/api/users", requireAuth, userRoutes);
app.use("/api/cleanup", requireAuth, cleanupRoutes);
app.use("/api/sf-mcp", requireAuth, sfMcpRoutes);
app.use("/api/bulk", requireAuth, bulkRoutes);
app.use("/api/account-hierarchy", requireAuth, accountHierarchyRoutes);

// Health check
app.get("/api/health", (_req, res) => {
  res.json({ status: "ok" });
});

app.listen(config.port, () => {
  console.log(`Server running on http://localhost:${config.port}`);
});
