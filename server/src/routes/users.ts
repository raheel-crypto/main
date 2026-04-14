import { Router } from "express";
import { getConnection } from "../services/salesforce.js";
import {
  listActiveUsers,
  getUserDetail,
  getUserRecordCounts,
  listProfiles,
  getProfilePermissions,
  listPermissionSets,
  getPermissionSetDetail,
} from "../services/userAnalyzer.js";

const router = Router();

router.get("/", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const users = await listActiveUsers(conn);
    res.json(users);
  } catch (error: any) {
    console.error("Error listing users:", error);
    res.status(500).json({ message: error.message });
  }
});

router.get("/profiles", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const profiles = await listProfiles(conn);
    res.json(profiles);
  } catch (error: any) {
    console.error("Error listing profiles:", error);
    res.status(500).json({ message: error.message });
  }
});

router.get("/profiles/:id/permissions", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const permissions = await getProfilePermissions(conn, req.params.id);
    res.json(permissions);
  } catch (error: any) {
    console.error("Error getting profile permissions:", error);
    res.status(500).json({ message: error.message });
  }
});

router.get("/permission-sets", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const permSets = await listPermissionSets(conn);
    res.json(permSets);
  } catch (error: any) {
    console.error("Error listing permission sets:", error);
    res.status(500).json({ message: error.message });
  }
});

router.get("/permission-sets/:id", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const detail = await getPermissionSetDetail(conn, req.params.id);
    res.json(detail);
  } catch (error: any) {
    console.error("Error getting permission set detail:", error);
    res.status(500).json({ message: error.message });
  }
});

router.get("/:id", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const user = await getUserDetail(conn, req.params.id);
    res.json(user);
  } catch (error: any) {
    console.error("Error getting user detail:", error);
    res.status(500).json({ message: error.message });
  }
});

router.get("/:id/records", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const counts = await getUserRecordCounts(conn, req.params.id);
    res.json(counts);
  } catch (error: any) {
    console.error("Error getting record counts:", error);
    res.status(500).json({ message: error.message });
  }
});

export default router;
