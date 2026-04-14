import { Connection } from "jsforce";

export interface CleanupFinding {
  category: string;
  severity: "high" | "medium" | "low";
  item: string;
  object: string | null;
  detail: string;
  recommendation: string;
}

export async function runFullCleanupScan(
  conn: Connection
): Promise<CleanupFinding[]> {
  const findings: CleanupFinding[] = [];

  console.log("[cleanup] Starting full cleanup scan...");

  const [fieldFindings, flowFindings, permFindings, userFindings] =
    await Promise.all([
      scanUnusedFields(conn).catch((e) => {
        console.log(`[cleanup] Field scan error: ${e.message}`);
        return [] as CleanupFinding[];
      }),
      scanStaleFlows(conn).catch((e) => {
        console.log(`[cleanup] Flow scan error: ${e.message}`);
        return [] as CleanupFinding[];
      }),
      scanUnusedPermissions(conn).catch((e) => {
        console.log(`[cleanup] Permission scan error: ${e.message}`);
        return [] as CleanupFinding[];
      }),
      scanInactiveUsers(conn).catch((e) => {
        console.log(`[cleanup] User scan error: ${e.message}`);
        return [] as CleanupFinding[];
      }),
    ]);

  findings.push(...fieldFindings, ...flowFindings, ...permFindings, ...userFindings);
  console.log(`[cleanup] Scan complete. ${findings.length} findings.`);
  return findings;
}

async function scanUnusedFields(conn: Connection): Promise<CleanupFinding[]> {
  const findings: CleanupFinding[] = [];

  // Get custom objects to scan
  const globalDesc = await conn.describeGlobal();
  const customObjects = globalDesc.sobjects
    .filter((o) => o.custom && o.queryable && !o.name.includes("__mdt") && !o.name.includes("__e"))
    .slice(0, 30); // Limit to avoid API limits

  // Also scan key standard objects
  const standardObjects = ["Account", "Contact", "Opportunity", "Lead", "Case"]
    .filter((name) => globalDesc.sobjects.some((o) => o.name === name));

  const objectsToScan = [
    ...standardObjects.map((name) => ({ name, custom: false })),
    ...customObjects.map((o) => ({ name: o.name, custom: true })),
  ];

  for (const obj of objectsToScan) {
    try {
      const desc = await conn.describe(obj.name);
      const customFields = desc.fields.filter((f) => f.custom);

      for (const field of customFields) {
        // Check if field has no description (documentation gap)
        if (!field.inlineHelpText && !field.label.includes("__c")) {
          findings.push({
            category: "Unused Fields",
            severity: "low",
            item: `${obj.name}.${field.name}`,
            object: obj.name,
            detail: `Custom field "${field.label}" has no description/help text.`,
            recommendation: `Add a description to ${field.name} so other admins understand its purpose.`,
          });
        }

        // Check for empty fields by sampling records
        try {
          const countQuery = `SELECT COUNT() FROM ${obj.name} WHERE ${field.name} != null LIMIT 1`;
          const countResult = await conn.query(countQuery);
          if (countResult.totalSize === 0) {
            findings.push({
              category: "Unused Fields",
              severity: "high",
              item: `${obj.name}.${field.name}`,
              object: obj.name,
              detail: `Custom field "${field.label}" (${field.type}) has no data in any record.`,
              recommendation: `Consider removing ${field.name} if it's not needed. Check flows and apex first.`,
            });
          }
        } catch {
          // Field might not be queryable with != null (e.g., rich text)
        }
      }
    } catch {
      // Skip objects we can't describe
    }
  }

  return findings;
}

async function scanStaleFlows(conn: Connection): Promise<CleanupFinding[]> {
  const findings: CleanupFinding[] = [];

  const result = await conn.tooling.query<{
    Id: string;
    Definition: { DeveloperName: string } | null;
    MasterLabel: string;
    ProcessType: string;
    Status: string;
    VersionNumber: number;
    Description: string | null;
  }>(`
    SELECT Id, Definition.DeveloperName, MasterLabel, ProcessType,
           Status, VersionNumber, Description
    FROM Flow
    ORDER BY MasterLabel
  `);

  // Group by flow name
  const flowGroups = new Map<string, typeof result.records>();
  for (const f of result.records || []) {
    const key = f.Definition?.DeveloperName || f.MasterLabel;
    if (!flowGroups.has(key)) flowGroups.set(key, []);
    flowGroups.get(key)!.push(f);
  }

  for (const [name, versions] of flowGroups) {
    const activeVersions = versions.filter((v) => v.Status === "Active");
    const obsoleteVersions = versions.filter((v) => v.Status === "Obsolete");
    const draftVersions = versions.filter((v) => v.Status === "Draft");

    // Flows with no active version
    if (activeVersions.length === 0 && versions.length > 0) {
      findings.push({
        category: "Stale Flows",
        severity: "medium",
        item: name,
        object: null,
        detail: `Flow "${versions[0].MasterLabel}" has ${versions.length} version(s) but none are active.`,
        recommendation: `Review if this flow is still needed. If not, delete it. If needed, activate the latest version.`,
      });
    }

    // Flows with many obsolete versions (clutter)
    if (obsoleteVersions.length >= 5) {
      findings.push({
        category: "Stale Flows",
        severity: "low",
        item: name,
        object: null,
        detail: `Flow "${versions[0].MasterLabel}" has ${obsoleteVersions.length} obsolete versions.`,
        recommendation: `Clean up old versions to reduce org clutter.`,
      });
    }

    // Flows with no description
    if (activeVersions.length > 0 && !activeVersions[0].Description) {
      findings.push({
        category: "Stale Flows",
        severity: "low",
        item: name,
        object: null,
        detail: `Active flow "${versions[0].MasterLabel}" has no description.`,
        recommendation: `Add a description explaining what this flow does and when it triggers.`,
      });
    }
  }

  return findings;
}

async function scanUnusedPermissions(conn: Connection): Promise<CleanupFinding[]> {
  const findings: CleanupFinding[] = [];

  // Permission sets with no assignments
  const psResult = await conn.query<{
    Id: string;
    Name: string;
    Label: string;
    IsOwnedByProfile: boolean;
    Assignments: { totalSize: number } | null;
  }>(`
    SELECT Id, Name, Label, IsOwnedByProfile,
           (SELECT Id FROM Assignments LIMIT 1)
    FROM PermissionSet
    WHERE IsOwnedByProfile = false
    ORDER BY Label
  `);

  for (const ps of psResult.records || []) {
    if (!ps.Assignments || ps.Assignments.totalSize === 0) {
      findings.push({
        category: "Unused Permissions",
        severity: "medium",
        item: ps.Label,
        object: null,
        detail: `Permission set "${ps.Label}" (${ps.Name}) is not assigned to any user.`,
        recommendation: `If this permission set is no longer needed, remove it to simplify your security model.`,
      });
    }
  }

  // Profiles with no active users
  const profileResult = await conn.query<{
    Id: string;
    Name: string;
    Users: { totalSize: number } | null;
  }>(`
    SELECT Id, Name,
           (SELECT Id FROM Users WHERE IsActive = true LIMIT 1)
    FROM Profile
    ORDER BY Name
  `);

  for (const p of profileResult.records || []) {
    if (!p.Users || p.Users.totalSize === 0) {
      findings.push({
        category: "Unused Permissions",
        severity: "low",
        item: p.Name,
        object: null,
        detail: `Profile "${p.Name}" has no active users assigned.`,
        recommendation: `Review if this profile is still needed. Unused profiles add complexity.`,
      });
    }
  }

  return findings;
}

async function scanInactiveUsers(conn: Connection): Promise<CleanupFinding[]> {
  const findings: CleanupFinding[] = [];

  const sixtyDaysAgo = new Date(Date.now() - 60 * 24 * 60 * 60 * 1000)
    .toISOString()
    .split("T")[0];

  const neverLoggedIn = await conn.query<{
    Id: string;
    Name: string;
    Email: string;
    Username: string;
    Profile: { Name: string; UserLicense: { Name: string } | null };
    CreatedDate: string;
  }>(`
    SELECT Id, Name, Email, Username, Profile.Name,
           CreatedDate, Profile.UserLicense.Name
    FROM User
    WHERE IsActive = true AND LastLoginDate = null
    ORDER BY Name
  `);

  for (const u of neverLoggedIn.records || []) {
    findings.push({
      category: "Inactive Users",
      severity: "high",
      item: u.Name,
      object: null,
      detail: `"${u.Name}" (${u.Email}) has NEVER logged in. Profile: ${u.Profile?.Name}. License: ${u.Profile?.UserLicense?.Name || "Unknown"}.`,
      recommendation: `Deactivate this user to free up a license, or verify they still need access.`,
    });
  }

  const dormant = await conn.query<{
    Id: string;
    Name: string;
    Email: string;
    LastLoginDate: string;
    Profile: { Name: string };
  }>(`
    SELECT Id, Name, Email, LastLoginDate, Profile.Name
    FROM User
    WHERE IsActive = true
      AND LastLoginDate < ${sixtyDaysAgo}T00:00:00Z
      AND LastLoginDate != null
    ORDER BY LastLoginDate ASC
  `);

  for (const u of dormant.records || []) {
    const daysSince = Math.floor(
      (Date.now() - new Date(u.LastLoginDate).getTime()) / (1000 * 60 * 60 * 24)
    );
    findings.push({
      category: "Inactive Users",
      severity: daysSince > 180 ? "high" : "medium",
      item: u.Name,
      object: null,
      detail: `"${u.Name}" (${u.Email}) last logged in ${daysSince} days ago (${new Date(u.LastLoginDate).toLocaleDateString()}). Profile: ${u.Profile?.Name}.`,
      recommendation: `Verify this user still needs access. Deactivate to free up a license if not.`,
    });
  }

  return findings;
}
