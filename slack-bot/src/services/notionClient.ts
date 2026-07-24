/**
 * Thin Notion REST client. Org-wide bearer token (no per-rep OAuth in v1).
 * Pages must be shared with the integration via Notion's Share menu, or the
 * API returns object_not_found.
 *
 * Block flattening: paragraphs, headings, list items, to-dos, quotes, callouts,
 * code blocks, dividers. Recursive descent into child_page / column_list /
 * column / toggle / synced_block, bounded by NOTION_MAX_DEPTH so a deeply
 * nested page can't run away.
 */
import { config } from "../config.js";
import { NOTION_MAX_CHARS } from "../constants.js";

const NOTION_API = "https://api.notion.com/v1";
const NOTION_VERSION = "2022-06-28";
const NOTION_MAX_DEPTH = 4;
const PAGE_FETCH_TIMEOUT_MS = 30_000;

export class NotionApiError extends Error {
  constructor(
    message: string,
    public code: string,
    public status?: number
  ) {
    super(message);
  }
}

/**
 * Pull a Notion page id out of any URL form: notion.so/title-<32hex>,
 * notion.so/workspace/title-<32hex>, notion.so/<32hex>, with or without
 * dashes. Returns the canonical UUID form (8-4-4-4-12).
 */
export function extractPageId(input: string): string | null {
  const cleaned = input.trim();
  // Match a 32-hex run (with optional dashes) anywhere in the input.
  const match = cleaned.match(
    /([0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12})/i
  );
  if (!match) return null;
  const raw = match[1].replace(/-/g, "");
  if (raw.length !== 32) return null;
  return `${raw.slice(0, 8)}-${raw.slice(8, 12)}-${raw.slice(12, 16)}-${raw.slice(16, 20)}-${raw.slice(20)}`;
}

function authHeaders(): Record<string, string> {
  const token = config.notion?.token;
  if (!token) {
    throw new NotionApiError(
      "NOTION_TOKEN not configured. Set it on the slack-bot Vercel project " +
        "and share the page with the Notion integration.",
      "not_configured"
    );
  }
  return {
    Authorization: `Bearer ${token}`,
    "Notion-Version": NOTION_VERSION,
    "Content-Type": "application/json",
  };
}

async function notionFetch(path: string): Promise<any> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), PAGE_FETCH_TIMEOUT_MS);
  try {
    const res = await fetch(`${NOTION_API}${path}`, {
      method: "GET",
      headers: authHeaders(),
      signal: ctrl.signal,
    });
    const text = await res.text();
    let body: any = null;
    try {
      body = text ? JSON.parse(text) : null;
    } catch {
      body = { error: text };
    }
    if (!res.ok) {
      const code = body?.code ?? "http_error";
      const message = body?.message ?? text ?? `HTTP ${res.status}`;
      throw new NotionApiError(message, code, res.status);
    }
    return body;
  } finally {
    clearTimeout(timer);
  }
}

export interface NotionPageMeta {
  id: string;
  title: string;
  url: string | null;
}

export async function getPageMeta(pageId: string): Promise<NotionPageMeta> {
  const page = await notionFetch(`/pages/${pageId}`);
  // The title lives on a property whose type is "title". The property's
  // name varies per database; for a root page it's just "title".
  let title = "(untitled)";
  const props = page?.properties ?? {};
  for (const v of Object.values(props) as any[]) {
    if (v?.type === "title" && Array.isArray(v.title) && v.title.length > 0) {
      title = v.title.map((t: any) => t.plain_text ?? "").join("");
      break;
    }
  }
  return { id: page.id, title, url: page?.url ?? null };
}

/**
 * Recursively fetch child blocks and render them to plain text. Stops at
 * NOTION_MAX_CHARS or NOTION_MAX_DEPTH, whichever hits first.
 */
export async function fetchPageText(pageId: string): Promise<string> {
  const lines: string[] = [];
  let usedChars = 0;
  let truncated = false;

  async function walk(parentId: string, depth: number): Promise<void> {
    if (depth >= NOTION_MAX_DEPTH || truncated) return;
    let cursor: string | undefined;
    do {
      const path =
        `/blocks/${parentId}/children?page_size=100` +
        (cursor ? `&start_cursor=${cursor}` : "");
      const page = await notionFetch(path);
      const blocks: any[] = Array.isArray(page?.results) ? page.results : [];
      for (const block of blocks) {
        if (truncated) return;
        const text = blockToText(block, depth);
        if (text) {
          if (usedChars + text.length + 1 > NOTION_MAX_CHARS) {
            lines.push("[truncated]");
            truncated = true;
            return;
          }
          lines.push(text);
          usedChars += text.length + 1;
        }
        if (block?.has_children && depth + 1 < NOTION_MAX_DEPTH) {
          await walk(block.id, depth + 1);
        }
      }
      cursor = page?.next_cursor ?? undefined;
    } while (cursor && !truncated);
  }

  await walk(pageId, 0);
  return lines.join("\n");
}

function richTextToString(rt: any[] | undefined): string {
  if (!Array.isArray(rt)) return "";
  return rt.map((t: any) => t?.plain_text ?? "").join("");
}

function blockToText(block: any, depth: number): string {
  const indent = "  ".repeat(Math.max(0, depth));
  const type = block?.type;
  const node = block?.[type];
  if (!node) return "";

  switch (type) {
    case "paragraph":
      return `${indent}${richTextToString(node.rich_text)}`;
    case "heading_1":
      return `\n${indent}# ${richTextToString(node.rich_text)}`;
    case "heading_2":
      return `\n${indent}## ${richTextToString(node.rich_text)}`;
    case "heading_3":
      return `\n${indent}### ${richTextToString(node.rich_text)}`;
    case "bulleted_list_item":
      return `${indent}- ${richTextToString(node.rich_text)}`;
    case "numbered_list_item":
      return `${indent}1. ${richTextToString(node.rich_text)}`;
    case "to_do": {
      const box = node.checked ? "[x]" : "[ ]";
      return `${indent}- ${box} ${richTextToString(node.rich_text)}`;
    }
    case "quote":
      return `${indent}> ${richTextToString(node.rich_text)}`;
    case "callout": {
      const icon = node.icon?.emoji ?? "💡";
      return `${indent}${icon} ${richTextToString(node.rich_text)}`;
    }
    case "code":
      return `${indent}\`\`\`\n${richTextToString(node.rich_text)}\n${indent}\`\`\``;
    case "divider":
      return `${indent}---`;
    case "toggle":
      return `${indent}▸ ${richTextToString(node.rich_text)}`;
    case "child_page":
      return `${indent}📄 ${node.title ?? ""}`;
    case "child_database":
      return `${indent}🗂 ${node.title ?? ""}`;
    case "column_list":
    case "column":
    case "synced_block":
      return ""; // walked recursively, no own text
    default:
      // image, file, embed, bookmark, link_preview, table, etc. — skip
      return "";
  }
}
