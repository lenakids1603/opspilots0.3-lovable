#!/usr/bin/env node
// 通过 Supabase Management API 分块执行 SQL 文件。
// /database/query 端点对请求体有 ~4KB 限制，所以 SQL 文件用 `-- @@SPLIT@@` 注释分块。
// 用法: SUPABASE_ACCESS_TOKEN=sbp_xxx node scripts/apply-sql-chunks.mjs <project-ref> <sql-file>
import { readFileSync } from "node:fs";

const [ref, file] = process.argv.slice(2);
const token = process.env.SUPABASE_ACCESS_TOKEN;
if (!ref || !file || !token) {
  console.error("usage: SUPABASE_ACCESS_TOKEN=sbp_xxx node scripts/apply-sql-chunks.mjs <project-ref> <sql-file>");
  process.exit(1);
}

const sql = readFileSync(file, "utf8").replace(/^﻿/, "");
const chunks = sql.split(/^[ \t]*-- @@SPLIT@@.*$/m);

for (let i = 0; i < chunks.length; i++) {
  const chunk = chunks[i];
  const label = `chunk ${i + 1}/${chunks.length}`;
  const meaningful = chunk
    .split("\n")
    .filter((l) => l.trim() && !l.trim().startsWith("--"))
    .join("\n")
    .trim();
  if (!meaningful) {
    console.log(`${label}: comment-only, skipped`);
    continue;
  }
  const body = JSON.stringify({ query: chunk });
  const res = await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body,
  });
  const text = await res.text();
  if (!res.ok) {
    console.error(`${label} FAILED (HTTP ${res.status}, ${Buffer.byteLength(body)} bytes): ${text}`);
    process.exit(1);
  }
  console.log(`${label} ok (${Buffer.byteLength(body)} bytes): ${text.slice(0, 120)}`);
}
console.log("all chunks applied");
