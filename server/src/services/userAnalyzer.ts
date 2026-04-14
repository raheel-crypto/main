import { Connection } from "jsforce";

export async function listActiveUsers(conn: Connection) {
  const query = `
    SELECT Id, Name, Email, Username, ProfileId, Profile.Name,
           Profile.UserLicense.Name,
           UserRole.Name, LastLoginDate, IsActive, UserType,
           Title, Department, CompanyName,
           CreatedDate, ManagerId, Manager.Name
    FROM User
    WHERE IsActive = true
    ORDER BY Name
  `;

  const result = await conn.query<{
    Id: string;
    Name: string;
    Email: string;
    Username: string;
    ProfileId: string;
    Profile: { Name: string; UserLicense: { Name: string } | null };
    UserRole: { Name: string } | null;
    LastLoginDate: string | null;
    IsActive: boolean;
    UserType: string;
    Title: string | null;
    Department: string | null;
    CompanyName: string | null;
    CreatedDate: string;
    ManagerId: string | null;
    Manager: { Name: string } | null;
  }>(query);

  return (result.records || []).map((u) => ({
    id: u.Id,
    name: u.Name,
    email: u.Email,
    username: u.Username,
    profileId: u.ProfileId,
    profileName: u.Profile?.Name || "Unknown",
    roleName: u.UserRole?.Name || null,
    lastLogin: u.LastLoginDate,
    userType: u.UserType,
    license: u.Profile?.UserLicense?.Name || u.UserType,
    title: u.Title,
    department: u.Department,
    company: u.CompanyName,
    createdDate: u.CreatedDate,
    managerName: u.Manager?.Name || null,
  }));
}

export async function getUserDetail(conn: Connection, userId: string) {
  // Get user info
  const userQuery = `
    SELECT Id, Name, Email, Username, ProfileId, Profile.Name,
           Profile.UserLicense.Name,
           UserRole.Name, LastLoginDate, IsActive, UserType,
           Title, Department, CompanyName,
           CreatedDate, ManagerId, Manager.Name
    FROM User
    WHERE Id = '${userId}'
  `;

  const userResult = await conn.query<{
    Id: string;
    Name: string;
    Email: string;
    Username: string;
    ProfileId: string;
    Profile: { Name: string; UserLicense: { Name: string } | null };
    UserRole: { Name: string } | null;
    LastLoginDate: string | null;
    IsActive: boolean;
    UserType: string;
    Title: string | null;
    Department: string | null;
    CompanyName: string | null;
    CreatedDate: string;
    ManagerId: string | null;
    Manager: { Name: string } | null;
  }>(userQuery);

  const user = userResult.records?.[0];
  if (!user) throw new Error(`User not found: ${userId}`);

  // Get permission set assignments
  const psQuery = `
    SELECT PermissionSet.Name, PermissionSet.Label, PermissionSet.IsOwnedByProfile,
           PermissionSet.Description, PermissionSet.Id
    FROM PermissionSetAssignment
    WHERE AssigneeId = '${userId}'
    ORDER BY PermissionSet.Label
  `;

  const psResult = await conn.query<{
    PermissionSet: {
      Id: string;
      Name: string;
      Label: string;
      IsOwnedByProfile: boolean;
      Description: string | null;
    };
  }>(psQuery);

  const permissionSets = (psResult.records || [])
    .filter((ps) => !ps.PermissionSet.IsOwnedByProfile)
    .map((ps) => ({
      id: ps.PermissionSet.Id,
      name: ps.PermissionSet.Name,
      label: ps.PermissionSet.Label,
      description: ps.PermissionSet.Description,
    }));

  return {
    id: user.Id,
    name: user.Name,
    email: user.Email,
    username: user.Username,
    profileId: user.ProfileId,
    profileName: user.Profile?.Name || "Unknown",
    roleName: user.UserRole?.Name || null,
    lastLogin: user.LastLoginDate,
    userType: user.UserType,
    license: user.Profile?.UserLicense?.Name || user.UserType,
    title: user.Title,
    department: user.Department,
    company: user.CompanyName,
    createdDate: user.CreatedDate,
    managerName: user.Manager?.Name || null,
    permissionSets,
  };
}

export async function getUserRecordCounts(conn: Connection, userId: string) {
  // Get the list of objects that have OwnerId
  const globalDesc = await conn.describeGlobal();
  const ownableObjects = globalDesc.sobjects
    .filter((o) => o.queryable && !o.name.endsWith("__History") && !o.name.endsWith("__Feed"))
    .map((o) => o.name);

  // Check common objects that typically have OwnerId
  const commonObjects = [
    "Account", "Contact", "Opportunity", "Lead", "Case",
    "Task", "Event", "Campaign",
  ].filter((o) => ownableObjects.includes(o));

  // Also include custom objects
  const customObjects = ownableObjects
    .filter((o) => o.endsWith("__c") && !o.includes("__"))
    .slice(0, 20); // Limit to avoid too many queries

  const objectsToCheck = [...new Set([...commonObjects, ...customObjects])];

  const counts: { object: string; count: number }[] = [];

  // Run queries in batches to avoid governor limits
  for (const obj of objectsToCheck) {
    try {
      const countQuery = `SELECT COUNT() FROM ${obj} WHERE OwnerId = '${userId}'`;
      const countResult = await conn.query(countQuery);
      const count = countResult.totalSize || 0;
      if (count > 0) {
        counts.push({ object: obj, count });
      }
    } catch {
      // Object may not have OwnerId or user may not have access
    }
  }

  counts.sort((a, b) => b.count - a.count);
  return counts;
}

export async function listProfiles(conn: Connection) {
  const query = `
    SELECT Id, Name, UserType, Description,
           (SELECT Id FROM Users WHERE IsActive = true)
    FROM Profile
    ORDER BY Name
  `;

  const result = await conn.query<{
    Id: string;
    Name: string;
    UserType: string;
    Description: string | null;
    Users: { records: { Id: string }[] } | null;
  }>(query);

  return (result.records || []).map((p) => ({
    id: p.Id,
    name: p.Name,
    userType: p.UserType,
    description: p.Description,
    activeUserCount: p.Users?.records?.length || 0,
  }));
}

export async function getProfilePermissions(conn: Connection, profileId: string) {
  // Get the profile's permission set (every profile has an associated permission set)
  const psQuery = `
    SELECT Id, Name, Label
    FROM PermissionSet
    WHERE ProfileId = '${profileId}'
    LIMIT 1
  `;

  const psResult = await conn.tooling.query<{
    Id: string;
    Name: string;
    Label: string;
  }>(psQuery);

  const permissionSetId = psResult.records?.[0]?.Id;
  if (!permissionSetId) {
    return { objectPermissions: [], fieldPermissions: [] };
  }

  // Get object permissions
  const objPermQuery = `
    SELECT SobjectType, PermissionsCreate, PermissionsRead,
           PermissionsEdit, PermissionsDelete, PermissionsViewAllRecords,
           PermissionsModifyAllRecords
    FROM ObjectPermissions
    WHERE ParentId = '${permissionSetId}'
    ORDER BY SobjectType
  `;

  const objPermResult = await conn.query<{
    SobjectType: string;
    PermissionsCreate: boolean;
    PermissionsRead: boolean;
    PermissionsEdit: boolean;
    PermissionsDelete: boolean;
    PermissionsViewAllRecords: boolean;
    PermissionsModifyAllRecords: boolean;
  }>(objPermQuery);

  // Get field permissions
  const fieldPermQuery = `
    SELECT SobjectType, Field, PermissionsRead, PermissionsEdit
    FROM FieldPermissions
    WHERE ParentId = '${permissionSetId}'
    ORDER BY SobjectType, Field
  `;

  const fieldPermResult = await conn.query<{
    SobjectType: string;
    Field: string;
    PermissionsRead: boolean;
    PermissionsEdit: boolean;
  }>(fieldPermQuery);

  return {
    objectPermissions: (objPermResult.records || []).map((p) => ({
      object: p.SobjectType,
      create: p.PermissionsCreate,
      read: p.PermissionsRead,
      edit: p.PermissionsEdit,
      delete: p.PermissionsDelete,
      viewAll: p.PermissionsViewAllRecords,
      modifyAll: p.PermissionsModifyAllRecords,
    })),
    fieldPermissions: (fieldPermResult.records || []).map((p) => ({
      object: p.SobjectType,
      field: p.Field,
      read: p.PermissionsRead,
      edit: p.PermissionsEdit,
    })),
  };
}
