import { Router } from "express";
import { getConnection } from "../services/salesforce.js";
import { getFieldUsage } from "../services/metadata.js";

const router = Router();

router.get("/:object/:field/usage", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const usage = await getFieldUsage(
      conn,
      req.params.object,
      req.params.field
    );
    res.json(usage);
  } catch (error: any) {
    console.error("Error getting field usage:", error);
    res.status(500).json({ message: error.message });
  }
});

export default router;
