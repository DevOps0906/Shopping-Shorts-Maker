"""대행 파이프라인 PoC: cut_map JSON → 9:16 컷 편집 → 음성 → 한 줄 자막 → MP4, 원가 CSV.

사용:
  python poc/agency/run.py --demo                  # 합성 클립 생성 + 샘플 2편(15·20초)
  python poc/agency/run.py samples/x.json [...]     # 실제 cut_map (권리 확인 원본만)
표준 라이브러리 + ffmpeg/ffprobe만 쓴다. TTS·LLM은 기본 dry-run(호출 없음, 0원).
"""
from __future__ import annotations

import argparse
import csv
import json
import shutil
import subprocess
import sys
import time
from decimal import Decimal, ROUND_CEILING
from pathlib import Path

from adapters import ClaudeLLM, FishAudioTTS, Usage

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "out"
W, H, FPS = 1080, 1920, 30
TOLERANCE_SEC = 0.5
DEMO_SOURCES = [(1920, 1080), (1280, 720), (1080, 1080), (720, 1280), (640, 480)]


def ff(args: list[str], cwd: Path | None = None) -> None:
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args]
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        raise RuntimeError(f"ffmpeg 실패: {' '.join(cmd)}\n{r.stderr.strip()}")


def make_demo_sources() -> None:
    """권리 문제 없는 ffmpeg testsrc2 합성 클립 5개(8초, 비율 제각각)."""
    src = OUT / "demo" / "src"
    src.mkdir(parents=True, exist_ok=True)
    for i, (w, h) in enumerate(DEMO_SOURCES, 1):
        ff(["-f", "lavfi", "-i", f"testsrc2=size={w}x{h}:rate={FPS}:duration=8",
            "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", str(src / f"clip{i}.mp4")])
    print(f"합성 클립 {len(DEMO_SOURCES)}개 → {src}")


def load_cut_map(path: Path) -> dict:
    cm = json.loads(path.read_text(encoding="utf-8"))
    total = 0.0
    for c in cm["cuts"]:
        src = (path.parent / c["source"]).resolve()
        if not src.is_file():
            raise FileNotFoundError(f"컷 {c['no']} 원본 없음: {src}")
        if c["end"] <= c["start"]:
            raise ValueError(f"컷 {c['no']} 구간 오류: {c['start']}~{c['end']}")
        c["source_path"] = src
        total += c["end"] - c["start"]
    if abs(total - cm["target_sec"]) > TOLERANCE_SEC:
        raise ValueError(f"컷 길이 합 {total:.2f}초 ≠ target_sec {cm['target_sec']}")
    return cm


def ff_escape(path: str) -> str:
    return path.replace("\\", "/").replace(":", r"\:")


def render(cm: dict, cfg: dict, tts: FishAudioTTS) -> tuple[Path, list[Usage]]:
    work = OUT / cm["project"]
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    usages: list[Usage] = []

    # 1) 컷마다 구간 자르기 → 비율 유지 확대 후 9:16 중앙 크롭
    vf = f"scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},setsar=1,fps={FPS}"
    concat_lines, t, timeline = [], 0.0, []
    for c in cm["cuts"]:
        dur = c["end"] - c["start"]
        name = f"cut_{c['no']}.mp4"
        ff(["-ss", str(c["start"]), "-t", str(dur), "-i", str(c["source_path"]), "-vf", vf, "-an",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p", name], cwd=work)
        concat_lines.append(f"file '{name}'")
        timeline.append((c, t, t + dur))
        t += dur
    (work / "concat.txt").write_text("\n".join(concat_lines) + "\n", encoding="utf-8")

    # 2) 이어 붙이기
    ff(["-f", "concat", "-safe", "0", "-i", "concat.txt", "-c", "copy", "video.mp4"], cwd=work)

    # 3) 음성: tts는 어댑터 호출, dry-run이면 합성 톤으로 대체. silent는 무음.
    mode = cm.get("audio", {}).get("mode", "silent")
    voice_audio = None
    if mode == "tts":
        script = " ".join(c["line"] for c in cm["cuts"])
        voice_audio, u = tts.synthesize(script, cm["audio"].get("voice_id", ""), str(work / "voice.wav"))
        usages.append(u)
    target = cm["target_sec"]
    if voice_audio:
        audio_in = ["-i", voice_audio]
    elif mode == "silent":
        audio_in = ["-f", "lavfi", "-i", f"anullsrc=r=48000:cl=stereo:d={target}"]
    else:
        audio_in = ["-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=48000:duration={target}"]

    # 4) 한 줄 자막: 컷 구간마다 drawtext (문구는 UTF-8 파일로 넘겨 이스케이프 문제 회피)
    font = cfg.get("subtitle_font", "")
    font_opt = f"fontfile='{ff_escape(font)}'" if font and Path(font).is_file() else "font='sans'"
    draws = []
    for c, a, b in timeline:
        txt = f"sub_{c['no']}.txt"
        (work / txt).write_text(c["line"], encoding="utf-8")
        draws.append(f"drawtext={font_opt}:textfile={txt}:fontsize=64:fontcolor=white:box=1:boxcolor=black@0.5:"
                     f"boxborderw=20:x=(w-text_w)/2:y=h*0.75:enable='between(t,{a:.3f},{b:.3f})'")
    final = work / f"{cm['project']}.mp4"
    ff(["-i", "video.mp4", *audio_in, "-vf", ",".join(draws), "-map", "0:v", "-map", "1:a",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "128k", "-t", str(target), "-movflags", "+faststart", final.name], cwd=work)
    return final, usages


def probe(path: Path) -> dict:
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type,width,height:format=duration",
                        "-of", "json", str(path)], capture_output=True, text=True, check=True)
    return json.loads(r.stdout)


def verify(path: Path, target: float) -> list[str]:
    info = probe(path)
    v = [s for s in info["streams"] if s["codec_type"] == "video"]
    a = [s for s in info["streams"] if s["codec_type"] == "audio"]
    dur = float(info["format"]["duration"])
    errs = []
    if not v or (v[0]["width"], v[0]["height"]) != (W, H):
        errs.append(f"해상도 {v[0]['width'] if v else '?'}x{v[0]['height'] if v else '?'} ≠ {W}x{H}")
    if not a:
        errs.append("음성 트랙 없음")
    if abs(dur - target) > TOLERANCE_SEC:
        errs.append(f"길이 {dur:.2f}초 ≠ {target}±{TOLERANCE_SEC}")
    print(f"  ffprobe {path.name}: {v[0]['width']}x{v[0]['height']} {dur:.2f}초 → {'통과' if not errs else '실패'}")
    return errs


def dec(s: str) -> Decimal | None:
    return Decimal(s) if str(s).strip() else None


def to_krw(x: Decimal) -> int:
    return int(x.to_integral_value(rounding=ROUND_CEILING))  # 원 단위 올림(보수적)


def cost_rows(project: str, usages: list[Usage], render_sec: float, cfg: dict) -> list[dict]:
    p, fx = cfg["pricing"], dec(cfg.get("usd_krw", ""))
    rows = []
    for u in usages:
        if u.provider == "claude":
            pin, pout = dec(p["claude"]["input_per_1m_tokens_usd"]), dec(p["claude"]["output_per_1m_tokens_usd"])
            it, ot = u.units["input_tokens"], u.units["output_tokens"]
            usage = f"input_tokens={it}; output_tokens={ot}(추정)"
            formula = "(input_tokens×input_per_1m + output_tokens×output_per_1m)/1e6×usd_krw"
            est = None if None in (pin, pout, fx) else to_krw((it * pin + ot * pout) / Decimal(10**6) * fx)
        elif u.provider == "fish_audio":
            unit = p["fish_audio"]["billing_unit"]
            price, n = dec(p["fish_audio"]["per_1m_units_usd"]), u.units[unit]
            usage = f"{unit}={n}"
            formula = f"{unit}×per_1m_units_usd/1e6×usd_krw"
            est = None if None in (price, fx) else to_krw(n * price / Decimal(10**6) * fx)
        else:
            continue
        rows.append({"project": project, "provider": u.provider, "item": u.item, "usage": usage,
                     "formula": formula, "estimated_krw": "" if est is None else est,
                     "billed_krw": 0 if u.dry_run else (est or 0), "mode": "dry-run" if u.dry_run else "live"})
    ph = dec(p["render_local"]["per_hour_krw"])
    est = None if ph is None else to_krw(Decimal(str(render_sec)) * ph / 3600)
    rows.append({"project": project, "provider": "render_local", "item": "ffmpeg", "usage": f"render_sec={render_sec:.2f}",
                 "formula": "render_sec×per_hour_krw/3600", "estimated_krw": "" if est is None else est,
                 "billed_krw": est or 0, "mode": "measured"})
    total_est = [r["estimated_krw"] for r in rows]
    rows.append({"project": project, "provider": "TOTAL", "item": "", "usage": "", "formula": "합계",
                 "estimated_krw": sum(total_est) if all(x != "" for x in total_est) else "",
                 "billed_krw": sum(r["billed_krw"] for r in rows), "mode": ""})
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description="대행 파이프라인 PoC")
    ap.add_argument("cut_maps", nargs="*", type=Path, help="cut_map JSON 경로")
    ap.add_argument("--demo", action="store_true", help="합성 클립으로 samples/demo_*.json 실행")
    ap.add_argument("--live", action="store_true", help="실제 API 호출(아직 미구현, 키는 환경 변수)")
    args = ap.parse_args()

    cfg = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))
    maps = list(args.cut_maps)
    if args.demo:
        make_demo_sources()
        maps += sorted((ROOT / "samples").glob("demo_*.json"))
    if not maps:
        ap.error("cut_map 경로 또는 --demo 가 필요합니다")

    tts, llm = FishAudioTTS(dry_run=not args.live), ClaudeLLM(dry_run=not args.live)
    all_rows, failures = [], 0
    for path in maps:
        cm = load_cut_map(path)
        print(f"[{cm['project']}] 컷 {len(cm['cuts'])}개, 목표 {cm['target_sec']}초")
        script_prompt = "다음 대사를 쇼츠 대본으로 다듬어 주세요:\n" + "\n".join(c["line"] for c in cm["cuts"])
        _, llm_usage = llm.complete(script_prompt)
        t0 = time.perf_counter()
        final, usages = render(cm, cfg, tts)
        render_sec = time.perf_counter() - t0
        errs = verify(final, cm["target_sec"])
        for e in errs:
            print(f"  실패: {e}")
        failures += bool(errs)
        all_rows += cost_rows(cm["project"], [llm_usage, *usages], render_sec, cfg)

    csv_path = OUT / "costs.csv"
    with csv_path.open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(all_rows[0].keys()))
        w.writeheader()
        w.writerows(all_rows)
    print(f"원가 표 → {csv_path}")
    for r in all_rows:
        print(f"  {r['project']:<10} {r['provider']:<13} {r['usage']:<42} 예상 {str(r['estimated_krw']) or '-':>6}원  청구 {r['billed_krw']}원")
    print("검증 통과" if not failures else f"검증 실패 {failures}건")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
