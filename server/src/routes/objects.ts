import { Router } from "express";
import { getConnection } from "../services/salesforce.js";
import {
  listObjects,
  describeObject,
  getObjectAutomations,
} from "../services/metadata.js";

const router = Router();

router.get("/", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const filter = req.query.filter as string | undefined;
    const objects = await listObjects(conn, filter);
    res.json(objects);
  } catch (error: any) {
    console.error("Error listing objects:", error);
    res.status(500).json({ message: error.message });
  }
});

router.get("/:name", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const detail = await describeObject(conn, req.params.name);
    res.json(detail);
  } catch (error: any) {
    console.error("Error describing object:", error);
    res.status(500).json({ message: error.message });
  }
});

router.get("/:name/automations", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const automations = await getObjectAutomations(conn, req.params.name);
    res.json(automations);
  } catch (error: any) {
    console.error("Error getting automations:", error);
    res.status(500).json({ message: error.message });
  }
});

export default router;
