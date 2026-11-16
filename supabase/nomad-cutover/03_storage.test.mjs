// 03_storage.mjs 단위 검증 + 가짜 Storage API 로 dry-run·apply·재실행·대조. 실행: node --test supabase/nomad-cutover/03_storage.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseMap, newPath, plan, verify, run } from "./03_storage.mjs";

const U1 = "a0000000-0000-4000-8000-000000000001";
const U2 = "b0000000-0000-4000-8000-000000000002";
const O1 = "0a000000-0000-4000-8000-0000000000a1";
const O2 = "0b000000-0000-4000-8000-0000000000b2";
const P1 = "ab000000-0000-4000-8000-000000000001";
const MAP = `user_id,organization_id\n${U1},${O1}\r\n${U2},${O2}\n`;

test("parseMap: 머리글·CRLF 허용, 형식 오류·중복 거부", () => {
  const m = parseMap(MAP);
  assert.equal(m.get(U1), O1);
  assert.equal(m.size, 2);
  assert.throws(() => parseMap(`${U1},not-a-uuid`), /형식 오류/);
  assert.throws(() => parseMap(`${U1},${O1}\n${U1},${O2}`), /두 번/);
  assert.throws(() => parseMap(`${U1},${O1},x`), /형식 오류/);
});

test("newPath: 첫 폴더만 user→org, 나머지 그대로", () => {
  const m = parseMap(MAP);
  assert.equal(newPath(`${U1}/${P1}/src-1.mp4`, m), `${O1}/${P1}/src-1.mp4`);
  assert.equal(newPath(`${U1}/${P1}/a/b/${U1}.mp4`, m), `${O1}/${P1}/a/b/${U1}.mp4`);
  assert.equal(newPath(`ffffffff-0000-4000-8000-000000000000/${P1}/x`, m), null);
  assert.equal(newPath("no-folder.mp4", m), null);
});

test("plan·verify: 버킷 대응, 대응 없는 객체, 없음·크기 다름", () => {
  const m = parseMap(MAP);
  const p = plan({
    sources: [{ name: `${U1}/${P1}/s.mp4`, size: 10 }],
    thumbnails: [{ name: `${U2}/${P1}/t.jpg`, size: 2 }, { name: "orphan/x.jpg", size: 1 }],
  }, m);
  assert.deepEqual(p.copies.map((c) => `${c.toBucket}/${c.to}`), [`shorts-sources/${O1}/${P1}/s.mp4`, `shorts-thumbnails/${O2}/${P1}/t.jpg`]);
  assert.deepEqual(p.unmapped, [{ bucket: "thumbnails", name: "orphan/x.jpg" }]);
  const v = verify(p.copies, { "shorts-sources": [{ name: `${O1}/${P1}/s.mp4`, size: 9 }] });
  assert.equal(v.missing.length, 1);
  assert.equal(v.sizeMismatch.length, 1);
});

// 가짜 Storage: 폴더는 id null 항목으로, 파일은 metadata.size 로 돌려준다(Storage list API 와 같은 모양)
function fakeStorage(initial) {
  const store = new Map(Object.entries(initial).map(([b, objs]) => [b, new Map(objs)]));
  const calls = [];
  const fetchImpl = async (url, init) => {
    const body = JSON.parse(init.body);
    assert.equal(init.headers.apikey, "test-key");
    assert.equal(init.headers.authorization, undefined);
    const path = new URL(url).pathname.replace("/storage/v1", "");
    calls.push(path);
    const json = (status, data) => ({ ok: status < 300, status, text: async () => JSON.stringify(data) });
    if (path.startsWith("/object/list/")) {
      const bucket = decodeURIComponent(path.slice("/object/list/".length));
      const objs = store.get(bucket) ?? new Map();
      const entries = new Map();
      for (const [name, size] of objs) {
        if (!name.startsWith(body.prefix)) continue;
        const rest = name.slice(body.prefix.length);
        const i = rest.indexOf("/");
        if (i >= 0) entries.set(rest.slice(0, i), { name: rest.slice(0, i), id: null, metadata: null });
        else entries.set(rest, { name: rest, id: `id-${name}`, metadata: { size } });
      }
      const list = [...entries.values()].sort((a, b) => a.name.localeCompare(b.name));
      return json(200, list.slice(body.offset, body.offset + body.limit));
    }
    if (path === "/object/copy") {
      const src = store.get(body.bucketId)?.get(body.sourceKey);
      if (src === undefined) return json(404, { error: "not_found" });
      if (!store.has(body.destinationBucket)) store.set(body.destinationBucket, new Map());
      const dst = store.get(body.destinationBucket);
      if (dst.has(body.destinationKey)) return json(400, { statusCode: "409", error: "Duplicate", message: "The resource already exists" });
      dst.set(body.destinationKey, src);
      return json(200, { Key: `${body.destinationBucket}/${body.destinationKey}` });
    }
    return json(404, {});
  };
  return { store, calls, fetchImpl };
}

const ENV = { SUPABASE_URL: "http://storage.test", SUPABASE_SERVICE_ROLE_KEY: "test-key" };
const OBJECTS = {
  sources: [[`${U1}/${P1}/src-1.mp4`, 1000], [`${U2}/${P1}/src-3.mp4`, 3000]],
  voices: [[`${U1}/${P1}/voice-1.mp3`, 50]],
  renders: [[`${U1}/${P1}/render-1.mp4`, 2000]],
  thumbnails: [[`${U1}/${P1}/thumb-1.jpg`, 5]],
};

test("run: dry-run 은 복사하지 않고 계획만", async () => {
  const s = fakeStorage(OBJECTS);
  const r = await run({ args: ["--map", "m.csv"], env: ENV, fetchImpl: s.fetchImpl, log: () => {}, readText: () => MAP });
  assert.equal(r.mode, "dry-run");
  assert.equal(r.copies.length, 5);
  assert.equal(r.ok, true);
  assert.ok(!s.calls.includes("/object/copy"));
  assert.equal(s.store.get("shorts-sources"), undefined);
});

test("run: apply 는 복사 후 대조, 재실행은 이미 있음으로 통과, 옛 객체 유지", async () => {
  const s = fakeStorage(OBJECTS);
  const opts = { args: ["--map", "m.csv", "--apply"], env: ENV, fetchImpl: s.fetchImpl, log: () => {}, readText: () => MAP };
  const r = await run(opts);
  assert.equal(r.ok, true, JSON.stringify(r));
  assert.equal(s.store.get("shorts-sources").get(`${O2}/${P1}/src-3.mp4`), 3000);
  assert.equal(s.store.get("shorts-thumbnails").get(`${O1}/${P1}/thumb-1.jpg`), 5);
  assert.equal(s.store.get("sources").size, 2);
  const again = await run(opts);
  assert.equal(again.ok, true);
});

test("run: 대응 없는 객체가 있으면 apply 중단, verify 는 크기 다름을 잡는다", async () => {
  const s = fakeStorage({ ...OBJECTS, voices: [[`ffffffff-0000-4000-8000-000000000000/${P1}/v.mp3`, 1]] });
  await assert.rejects(
    run({ args: ["--map", "m.csv", "--apply"], env: ENV, fetchImpl: s.fetchImpl, log: () => {}, readText: () => MAP }),
    /대응 없는 객체/);
  assert.ok(!s.calls.includes("/object/copy"));

  const t = fakeStorage({ ...OBJECTS, "shorts-renders": [[`${O1}/${P1}/render-1.mp4`, 1999]] });
  const v = await run({ args: ["--map", "m.csv", "--verify"], env: ENV, fetchImpl: t.fetchImpl, log: () => {}, readText: () => MAP });
  assert.equal(v.ok, false);
  assert.equal(v.sizeMismatch.length, 1);
  assert.equal(v.missing.length, 4);
});

test("run: 키 없으면 시작하지 않음", async () => {
  await assert.rejects(run({ args: ["--map", "m.csv"], env: {}, log: () => {}, readText: () => MAP }), /환경 변수/);
});
