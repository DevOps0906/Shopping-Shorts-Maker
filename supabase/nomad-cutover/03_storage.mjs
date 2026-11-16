#!/usr/bin/env node
// 03_storage.mjs — 옛 버킷 객체를 새 버킷·새 경로로 복사(Storage 서버 측 copy, 내려받지 않음). 옛 버킷·객체는 지우지 않는다.
//   sources→shorts-sources · voices→shorts-voices · renders→shorts-renders · thumbnails→shorts-thumbnails
//   경로 '<user_id>/<project_id>/…' → '<organization_id>/<project_id>/…' (02_copy.sql 이 DB 경로 열을 같은 규칙으로 바꾼다)
// 사용(Node 20+, 의존성 없음. 키는 환경 변수로만, 출력하지 않는다):
//   SUPABASE_URL=https://<ref>.supabase.co SUPABASE_SERVICE_ROLE_KEY=<service 키> \
//     node supabase/nomad-cutover/03_storage.mjs --map user_org.csv            # dry-run: 목록·계획만
//     node supabase/nomad-cutover/03_storage.mjs --map user_org.csv --apply    # 복사 → 개수·크기 대조
//     node supabase/nomad-cutover/03_storage.mjs --map user_org.csv --verify   # 대조만
//   user_org.csv 는 02 apply 뒤 docs/ops/NOMAD_DB_CUTOVER.md 의 \copy 명령으로 만든다(user_id,organization_id).
// 대응 없는 첫 폴더(개인 조직 없는 사용자)가 하나라도 있으면 --apply 는 복사하지 않고 끝난다.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export const BUCKETS = [
  ["sources", "shorts-sources"],
  ["voices", "shorts-voices"],
  ["renders", "shorts-renders"],
  ["thumbnails", "shorts-thumbnails"],
];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function parseMap(text) {
  const map = new Map();
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || /^user_id\s*,/i.test(line)) continue;
    const [user, org, extra] = line.split(",").map((s) => s.trim());
    if (extra !== undefined || !UUID.test(user ?? "") || !UUID.test(org ?? "")) {
      throw new Error(`대응표 형식 오류: ${line}`);
    }
    if (map.has(user)) throw new Error(`대응표에 같은 user_id 가 두 번: ${user}`);
    map.set(user.toLowerCase(), org.toLowerCase());
  }
  return map;
}

// 첫 폴더(user_id)를 조직 id 로. 대응 없으면 null.
export function newPath(path, map) {
  const i = path.indexOf("/");
  if (i <= 0) return null;
  const org = map.get(path.slice(0, i).toLowerCase());
  return org ? org + path.slice(i) : null;
}

// objects: { [oldBucket]: [{ name, size }] }
export function plan(objects, map) {
  const copies = [];
  const unmapped = [];
  for (const [from, to] of BUCKETS) {
    for (const o of objects[from] ?? []) {
      const dest = newPath(o.name, map);
      if (dest) copies.push({ fromBucket: from, from: o.name, toBucket: to, to: dest, size: o.size });
      else unmapped.push({ bucket: from, name: o.name });
    }
  }
  return { copies, unmapped };
}

// dst: { [newBucket]: [{ name, size }] } — 계획한 객체가 모두 같은 크기로 있어야 한다
export function verify(copies, dst) {
  const index = new Map();
  for (const [bucket, list] of Object.entries(dst)) for (const o of list) index.set(`${bucket}/${o.name}`, o.size);
  const missing = [];
  const sizeMismatch = [];
  for (const c of copies) {
    const key = `${c.toBucket}/${c.to}`;
    if (!index.has(key)) missing.push(key);
    else if (index.get(key) !== c.size) sizeMismatch.push(`${key} (원본 ${c.size}, 대상 ${index.get(key)})`);
  }
  return { missing, sizeMismatch };
}

function client(url, key, fetchImpl) {
  const headers = { apikey: key, "content-type": "application/json" };
  if (key.startsWith("eyJ")) headers.authorization = `Bearer ${key}`; // 옛 JWT 형식 키만 Bearer 로
  const base = url.replace(/\/+$/, "") + "/storage/v1";
  return async (path, body) => {
    const res = await fetchImpl(base + path, { method: "POST", headers, body: JSON.stringify(body) });
    const text = await res.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = text; }
    return { ok: res.ok, status: res.status, data };
  };
}

export async function listAll(call, bucket, prefix = "") {
  const out = [];
  for (let offset = 0; ; offset += 1000) {
    const r = await call(`/object/list/${encodeURIComponent(bucket)}`, {
      prefix, limit: 1000, offset, sortBy: { column: "name", order: "asc" },
    });
    if (!r.ok) throw new Error(`목록 실패 ${bucket}/${prefix}: HTTP ${r.status}`);
    for (const e of r.data) {
      if (e.id === null || e.id === undefined) out.push(...(await listAll(call, bucket, `${prefix}${e.name}/`)));
      else out.push({ name: prefix + e.name, size: e.metadata?.size ?? null });
    }
    if (r.data.length < 1000) return out;
  }
}

async function listBuckets(call, names) {
  const result = {};
  for (const b of names) result[b] = await listAll(call, b);
  return result;
}

export async function run({ args, env, fetchImpl = fetch, log = console.log, readText = (f) => readFileSync(f, "utf8") }) {
  const mi = args.indexOf("--map");
  if (mi < 0 || !args[mi + 1]) throw new Error("--map <user_org.csv> 가 필요합니다");
  const mode = args.includes("--apply") ? "apply" : args.includes("--verify") ? "verify" : "dry-run";
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("SUPABASE_URL · SUPABASE_SERVICE_ROLE_KEY 환경 변수가 필요합니다");
  }
  const map = parseMap(readText(args[mi + 1]));
  const call = client(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, fetchImpl);

  const src = await listBuckets(call, BUCKETS.map(([f]) => f));
  const p = plan(src, map);
  for (const [from, to] of BUCKETS) {
    const n = p.copies.filter((c) => c.fromBucket === from);
    log(`${from} → ${to}: ${n.length}개 ${n.reduce((s, c) => s + (c.size ?? 0), 0)}바이트`);
  }
  if (p.unmapped.length) {
    log(`대응 없는 객체 ${p.unmapped.length}개(첫 폴더가 대응표에 없음):`);
    for (const u of p.unmapped.slice(0, 20)) log(`  ${u.bucket}/${u.name}`);
  }
  if (mode === "dry-run") {
    log("dry-run: 복사하지 않았습니다. 실행은 --apply");
    return { mode, ...p, ok: p.unmapped.length === 0 };
  }
  if (mode === "apply") {
    if (p.unmapped.length) throw new Error("대응 없는 객체가 있어 복사하지 않습니다(중단)");
    let copied = 0;
    let existed = 0;
    for (const c of p.copies) {
      const r = await call("/object/copy", {
        bucketId: c.fromBucket, sourceKey: c.from, destinationBucket: c.toBucket, destinationKey: c.to,
      });
      if (r.ok) copied += 1;
      else if (r.status === 409 || /exist|duplicate/i.test(JSON.stringify(r.data))) existed += 1; // 재실행: 대조에서 크기 확인
      else throw new Error(`복사 실패 ${c.fromBucket}/${c.from} → ${c.toBucket}/${c.to}: HTTP ${r.status}`);
    }
    log(`복사 ${copied}개 · 이미 있음 ${existed}개`);
  }
  const dst = await listBuckets(call, BUCKETS.map(([, t]) => t));
  const v = verify(p.copies, dst);
  log(`대조: 계획 ${p.copies.length}개 · 없음 ${v.missing.length} · 크기 다름 ${v.sizeMismatch.length}`);
  for (const m of [...v.missing, ...v.sizeMismatch].slice(0, 20)) log(`  ${m}`);
  const ok = v.missing.length === 0 && v.sizeMismatch.length === 0 && p.unmapped.length === 0;
  return { mode, ...p, ...v, ok };
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  run({ args: process.argv.slice(2), env: process.env })
    .then((r) => { if (!r.ok) process.exitCode = 1; })
    .catch((e) => { console.error(`03_storage 중단: ${e.message}`); process.exitCode = 1; });
}
