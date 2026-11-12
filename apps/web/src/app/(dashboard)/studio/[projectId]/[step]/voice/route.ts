import { NextResponse } from "next/server";
import { RECORDING_ERRORS, RECORDING_MAX_BYTES } from "@/lib/voice/recording";
import { checkRecordingAccess, uploadRecording } from "@/server/voice/voice";

/*
 * 04 목소리 직접 녹음 업로드: POST /studio/[projectId]/voice/voice (multipart: file · durationSec).
 * 서버 액션 본문 상한(1MB)을 넘는 녹음 파일이 있어 Route Handler 로 받는다.
 * 순서: 인증·소유권·단계 확인 → Content-Length 필수(없으면 411) → 본문 스트림을 세며 읽고 상한+여유를 넘으면 413
 * → 형식·길이 검사·저장(server/voice).
 */

const FORM_OVERHEAD = 64 * 1024;
const BODY_LIMIT = RECORDING_MAX_BYTES + FORM_OVERHEAD;

const fail = (error: string, status: number) => NextResponse.json({ ok: false, error }, { status });

async function readLimited(body: ReadableStream<Uint8Array>): Promise<Uint8Array<ArrayBuffer> | null> {
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > BODY_LIMIT) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(new ArrayBuffer(total));
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

export async function POST(request: Request, { params }: { params: Promise<{ projectId: string; step: string }> }) {
  const { projectId, step } = await params;
  if (step !== "voice") return fail("잘못된 요청입니다.", 404);

  const access = await checkRecordingAccess(projectId);
  if (!access.ok) return fail(access.error, 403);

  const length = request.headers.get("content-length");
  if (length === null) return fail("파일 크기를 알 수 없습니다. 다시 올려 주세요.", 411);
  if (!(Number(length) <= BODY_LIMIT)) return fail(RECORDING_ERRORS.tooBig, 413);
  if (!request.body) return fail(RECORDING_ERRORS.empty, 400);

  const bytes = await readLimited(request.body);
  if (!bytes) return fail(RECORDING_ERRORS.tooBig, 413);

  let form: FormData;
  try {
    form = await new Response(bytes, { headers: { "content-type": request.headers.get("content-type") ?? "" } }).formData();
  } catch {
    return fail(RECORDING_ERRORS.empty, 400);
  }
  const result = await uploadRecording(projectId, form.get("file"), form.get("durationSec"));
  return NextResponse.json(result, { status: result.ok ? 200 : 400 });
}
