"""대행 파이프라인 PoC: cut_map JSON → 9:16 컷 편집 → 음성 → 한 줄 자막 → MP4, 원가 CSV.

사용:
  python poc/agency/run.py --demo [--sources N]     # 합성 클립 생성 + 샘플 2편(15·20초)
  python poc/agency/run.py samples/x.json [...]     # 실제 cut_map (권리 확인 원본만)
표준 라이브러리 + ffmpeg/ffprobe만 쓴다. TTS·LLM은 기본 dry-run(호출 없음, 0원).
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import shutil
import subprocess
import sys
import time
from decimal import Decimal, ROUND_CEILING
from pathlib import Path

from adapters import ClaudeLLM, FishAudioTTS, GeminiTTS, GeminiVideo, Usage

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "out"
W, H, FPS = 1080, 1920, 30
TOLERANCE_SEC = 0.5
PAD_SEC, SYNC_TOL = 0.15, 0.2  # 문장 뒤 여유, 자막·무음 경계 허용 오차
SAMPLE_VOICES = ["Leda", "Laomedeia", "Zephyr", "Autonoe"]
SAMPLE_FALLBACK = "Sadachbia"
SAMPLE_TEXT = "좁은 틈에도 쏙 들어가요. 이거 하나면 정리 끝!"
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


PLATFORM_LABEL = {"tiktok": "TikTok", "xiaohongshu": "小红书"}


def credit_label(c: dict) -> str:
    """컷 원본의 '@작성자'. author가 없으면 빈 문자열(표기 생략)."""
    a = str(c.get("author", "")).strip().lstrip("@")
    return f"@{a}" if a else ""


def credits_text(cm: dict) -> str:
    """설명란용 출처 목록: '영상 출처: @a(TikTok), @b(小红书)' (중복 제거, 컷 순서)."""
    seen: list[str] = []
    for c in cm["cuts"]:
        lab = credit_label(c)
        if not lab:
            continue
        pf = c.get("platform", "")
        item = f"{lab}({PLATFORM_LABEL.get(pf, pf)})" if pf else lab
        if item not in seen:
            seen.append(item)
    return ("영상 출처: " + ", ".join(seen) + "\n") if seen else ""


def silence_gaps(path: str, d: float = 0.12) -> tuple[list[tuple[float, float]], float]:
    """ffmpeg silencedetect로 (무음 시작, 끝) 목록과 전체 길이를 돌려준다."""
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", f"silencedetect=noise=-35dB:d={d}",
                        "-f", "null", "-"], capture_output=True, text=True, encoding="utf-8", errors="replace")
    total = float(probe(Path(path))["format"]["duration"])
    starts = [float(x) for x in re.findall(r"silence_start: (-?[\d.]+)", r.stderr)]
    ends = [float(x) for x in re.findall(r"silence_end: (-?[\d.]+)", r.stderr)]
    gaps = [(max(s, 0.0), ends[i] if i < len(ends) else total) for i, s in enumerate(starts)]
    return gaps, total


def sentence_spans(wav: str, lines: list[str]) -> tuple[list[tuple[float, float]], str]:
    """한 번에 만든 음성에서 문장별 (시작, 끝). 가장 긴 N-1개 무음을 경계로 삼고, 모자라면 글자 수 비율."""
    gaps, total = silence_gaps(wav)
    lead, tail = 0.0, total
    if gaps and gaps[0][0] < 0.05:
        lead = gaps.pop(0)[1]
    if gaps and gaps[-1][1] >= total - 0.05:
        tail = gaps.pop()[0]
    merged: list[tuple[float, float]] = []  # 0.15초 미만 발화(숨소리 등)로 갈라진 무음은 하나로
    for g in gaps:
        if merged and g[0] - merged[-1][1] < 0.15:
            merged[-1] = (merged[-1][0], g[1])
        else:
            merged.append(g)
    gaps = merged
    n = len(lines)
    longest = lambda k: sorted(sorted(gaps, key=lambda g: g[1] - g[0], reverse=True)[:k])
    first_longest = bool(gaps) and gaps[0] == max(gaps, key=lambda g: g[1] - g[0])
    if len(gaps) >= n and first_longest:  # 말투 지시문을 읽어 버린 경우(첫 쉼이 가장 길고 앞 구간이 하나 더 있음): 앞을 버린다
        pick = longest(n)
        return [(pick[i][1], pick[i + 1][0] if i + 1 < n else tail) for i in range(n)], "silencedetect_skip_preface"
    if len(gaps) >= n - 1:
        pick = longest(n - 1)
        starts, ends = [lead] + [e for _, e in pick], [s for s, _ in pick] + [tail]
        return list(zip(starts, ends)), "silencedetect"
    w = [max(1, len(re.sub(r"\s", "", x))) for x in lines]
    spans, t = [], lead
    for x in w:
        spans.append((t, t + (tail - lead) * x / sum(w)))
        t = spans[-1][1]
    return spans, "char_ratio"


def quant(x: float) -> float:
    return math.ceil(x * FPS - 1e-6) / FPS  # 프레임 단위 올림


def plan_cuts(lines: list[str], target: float, spans: list[tuple[float, float]] | None) -> tuple[list[float], float]:
    """컷 길이 목록(프레임 단위, 합 = target)과 atempo. spans 없으면(dry-run) 글자 수 비율."""
    if spans is None:
        w = [max(1, len(re.sub(r"\s", "", x))) for x in lines]
        durs, tempo = [quant(target * x / sum(w)) for x in w], 1.0
    else:
        raw = [e - s + PAD_SEC for s, e in spans]
        total = sum(raw)
        tempo = max(0.9, total / target) if total < target else min(1.15, total / target)
        durs = [quant(r / tempo) for r in raw]
    durs[-1] = max(0.5, round(target - sum(durs[:-1]), 3))  # 남는 시간은 마지막 컷 유지, 넘치면 마지막 컷이 줄어듦
    return durs, tempo


def fit_voice(wav: str, spans: list[tuple[float, float]], durs: list[float], tempo: float, out: str) -> None:
    """문장 구간을 잘라 atempo 후 컷 길이에 맞춰 패딩·이어 붙인다(48kHz 스테레오). 컷 경계 = 음성 경계."""
    parts = [f"[0:a]atrim=start={s:.3f}:end={e:.3f},asetpts=PTS-STARTPTS,atempo={tempo:.4f},"
             f"apad=whole_dur={d:.3f},atrim=end={d:.3f},asetpts=PTS-STARTPTS[a{i}]"
             for i, ((s, e), d) in enumerate(zip(spans, durs))]
    cat = "".join(f"[a{i}]" for i in range(len(spans))) + f"concat=n={len(spans)}:v=0:a=1,aresample=48000,aformat=channel_layouts=stereo[o]"
    ff(["-i", wav, "-filter_complex", ";".join(parts + [cat]), "-map", "[o]", out])


def check_sync(final: Path, timing: dict) -> list[str]:
    """최종 영상 음성의 silencedetect 경계와 timing.json 자막 구간 끝이 SYNC_TOL 이내인지 확인."""
    gaps, total = silence_gaps(str(final), 0.1)
    inner = [g for g in gaps if g[0] > 0.05 and g[1] < total - 0.05]
    errs, worst = [], 0.0
    for s in timing["sentences"][:-1]:
        err = min((abs(e - s["sub_end"]) for _, e in inner), default=99.0)
        worst = max(worst, err)
        if err > SYNC_TOL:
            errs.append(f"문장 {s['no']} 자막 끝 {s['sub_end']:.2f}초 ↔ 무음 경계 오차 {err:.2f}초 > {SYNC_TOL}")
    timing["max_boundary_error_sec"] = round(worst, 3)
    print(f"  싱크: 경계 방식 {timing['method']}, atempo {timing['tempo']:.3f}, 최대 경계 오차 {worst:.3f}초")
    return errs


def trim_preface(src: str, dst: str) -> None:
    """샘플이 7초를 넘으면 말투 지시문을 읽은 것으로 보고, 가장 긴 쉼 뒤부터만 48kHz 스테레오 mp3로 저장."""
    gaps, total = silence_gaps(src, 0.3)
    gaps = [g for g in gaps if 0.05 < g[0] and g[1] < total - 0.05]
    start = max(gaps, key=lambda g: g[1] - g[0])[1] if total > 7 and gaps else 0.0
    if start:
        print(f"  경고: 말투 지시문 낭독 의심(길이 {total:.1f}초) → 앞 {start:.1f}초 잘라 냄")
    ff(["-ss", f"{start:.3f}", "-i", src, "-ar", "48000", "-ac", "2", "-b:a", "128k", dst])


def make_voice_samples(cfg: dict) -> None:
    """목소리 후보 샘플: 같은 문장을 후보별 1회씩 live 호출 → out/listen/voice_<이름>.mp3. 실패 시 대체 목소리 1회."""
    gc, listen = cfg.get("gemini", {}), OUT / "listen"
    listen.mkdir(parents=True, exist_ok=True)
    for name in SAMPLE_VOICES:
        for v in (name, SAMPLE_FALLBACK):
            wav = listen / f"voice_{v}.wav"
            try:
                GeminiTTS(False, gc.get("tts_model", ""), v, gc.get("tts_style", ""), gc.get("tts_style_mode", "system")).synthesize(SAMPLE_TEXT, "", str(wav))
                trim_preface(str(wav), str(listen / f"voice_{v}.mp3"))
                wav.unlink()
                print(f"  샘플 성공: {v} → {listen / f'voice_{v}.mp3'}")
                break
            except RuntimeError as e:
                print(f"  샘플 실패: {v}: {str(e)[:150]}")
                if v == SAMPLE_FALLBACK:
                    break


def render(cm: dict, cfg: dict, tts) -> tuple[Path, list[Usage]]:
    work = OUT / cm["project"]
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    usages: list[Usage] = []

    # 1) 음성 먼저(문장 단위 한 번에 생성): 컷 길이 = 문장 음성 길이. dry-run은 글자 수 비율, 무음은 원래 길이.
    mode = cm.get("audio", {}).get("mode", "silent")
    target, lines = cm["target_sec"], [c["line"] for c in cm["cuts"]]
    voice_audio, spans, method, tempo = None, None, "source_range", 1.0
    if mode == "tts":
        script = "\n".join(x if x[-1] in ".!?。" else x + "." for x in lines)  # 문장 사이 쉼 유도
        voice_audio, u = tts.synthesize(script, cm["audio"].get("voice_id", ""), str(work / "voice.wav"))
        usages.append(u)
        method = "char_ratio_dry"
        if voice_audio:
            spans, method = sentence_spans(voice_audio, lines)
        durs, tempo = plan_cuts(lines, target, spans)
        for c, d in zip(cm["cuts"], durs):
            c["dur"] = d
        if voice_audio:
            fit_voice(voice_audio, spans, durs, tempo, str(work / "voice_fit.wav"))
            voice_audio = str(work / "voice_fit.wav")

    # 2) 컷마다 구간 자르기 → 비율 유지 확대 후 9:16 중앙 크롭
    vf = f"scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},setsar=1,fps={FPS}"
    concat_lines, t, timeline = [], 0.0, []
    for c in cm["cuts"]:
        dur = c.get("dur", c["end"] - c["start"])
        name = f"cut_{c['no']}.mp4"
        # 원본 남은 길이가 컷보다 짧으면 마지막 프레임을 정지 화면으로 늘려 컷 길이를 채운다
        ff(["-ss", str(c["start"]), "-i", str(c["source_path"]), "-vf", f"{vf},tpad=stop_mode=clone:stop_duration={dur:.3f}",
            "-t", f"{dur:.3f}", "-an",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p", name], cwd=work)
        concat_lines.append(f"file '{name}'")
        timeline.append((c, t, t + dur))
        t += dur
    (work / "concat.txt").write_text("\n".join(concat_lines) + "\n", encoding="utf-8")
    ff(["-f", "concat", "-safe", "0", "-i", "concat.txt", "-c", "copy", "video.mp4"], cwd=work)

    # 3) 오디오 입력: tts는 맞춰 붙인 음성, dry-run이면 합성 톤, silent는 무음. 문장 시각은 timing.json에 저장.
    if voice_audio:
        audio_in = ["-i", voice_audio, "-af", "apad"]  # 음성이 짧으면 무음으로 target까지 채움
    elif mode == "silent":
        audio_in = ["-f", "lavfi", "-i", f"anullsrc=r=48000:cl=stereo:d={target}"]
    else:
        audio_in = ["-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=48000:duration={target}"]
    if mode == "tts":
        sents = []
        for i, (c, a, b) in enumerate(timeline):
            sp = (spans[i][1] - spans[i][0]) / tempo if spans else b - a
            sents.append({"no": c["no"], "line": c["line"], "speech_start": round(a, 3), "speech_end": round(a + min(sp, b - a), 3),
                          "sub_start": round(a, 3), "sub_end": round(b, 3)})
        timing = {"project": cm["project"], "target_sec": target, "method": method, "tempo": round(tempo, 4), "sentences": sents}
        (work / "timing.json").write_text(json.dumps(timing, ensure_ascii=False, indent=2), encoding="utf-8")

    # 4) 한 줄 자막: 컷 구간마다 drawtext (문구는 UTF-8 파일로 넘겨 이스케이프 문제 회피)
    font = cfg.get("subtitle_font", "")
    font_opt = f"fontfile='{ff_escape(font)}'" if font and Path(font).is_file() else "font='sans'"
    draws = []
    for c, a, b in timeline:
        txt = f"sub_{c['no']}.txt"
        (work / txt).write_text(c["line"], encoding="utf-8")
        draws.append(f"drawtext={font_opt}:textfile={txt}:fontsize=64:fontcolor=white:box=1:boxcolor=black@0.5:"
                     f"boxborderw=20:x=(w-text_w)/2:y=h*0.75:enable='between(t,{a:.3f},{b:.3f})'")
        au = credit_label(c)  # 원본 출처 표기: 우하단 작은 글씨(자막과 겹치지 않게 y=h*0.9)
        if au:
            ctxt = f"credit_{c['no']}.txt"
            (work / ctxt).write_text(au, encoding="utf-8")
            draws.append(f"drawtext={font_opt}:textfile={ctxt}:fontsize=h*0.02:fontcolor=white@0.9:box=1:"
                         f"boxcolor=black@0.4:boxborderw=8:x=w-text_w-40:y=h*0.9:enable='between(t,{a:.3f},{b:.3f})'")
    (work / "credits.txt").write_text(credits_text(cm), encoding="utf-8")
    final = work / f"{cm['project']}.mp4"
    ff(["-i", "video.mp4", *audio_in, "-vf", ",".join(draws), "-map", "0:v", "-map", "1:a",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2", "-t", str(target), "-movflags", "+faststart", final.name], cwd=work)
    return final, usages


def extract_frames(cm: dict, cfg: dict, work: Path) -> list[tuple[int, int]]:
    """컷마다 대표 프레임 N장을 ffmpeg로 뽑아 저장하고 (w, h) 목록을 돌려준다(API 호출 없음)."""
    n = max(1, int(cfg.get("vision", {}).get("frames_per_cut", 1)))
    fdir = work / "frames"
    fdir.mkdir(exist_ok=True)
    sizes = []
    for c in cm["cuts"]:
        dur = c["end"] - c["start"]
        for k in range(n):
            png = fdir / f"cut_{c['no']}_{k + 1}.png"
            ff(["-ss", f"{c['start'] + dur * (k + 0.5) / n:.3f}", "-i", str(c["source_path"]),
                "-frames:v", "1", str(png)])
            st = probe_video_size(png)
            sizes.append(st)
    return sizes


def probe_video_size(path: Path) -> tuple[int, int]:
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                        "-of", "csv=p=0:s=x", str(path)], capture_output=True, text=True, encoding="utf-8")
    w, h = r.stdout.strip().split("x")
    return int(w), int(h)


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
        if u.provider == "claude" and u.item == "vision":
            pin, it = dec(p["claude"]["input_per_1m_tokens_usd"]), u.units["input_tokens"]
            usage = f"images={u.units['images']}; input_tokens={it}(추정)"
            formula = "ceil(w×h/750)(긴 변 1568px 초과 시 축소)합 ×input_per_1m/1e6×usd_krw"
            est = None if None in (pin, fx) else to_krw(it * pin / Decimal(10**6) * fx)
        elif u.provider == "claude":
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
        elif u.provider == "gemini_tts":
            g = p.get("gemini_tts", {})
            pin, pout = dec(g.get("input_per_1m_tokens_usd", "")), dec(g.get("output_per_1m_tokens_usd", ""))
            it, ot = u.units.get("input_tokens", 0), u.units.get("output_tokens", 0)
            usage = f"input_tokens={it}; output_tokens={ot}; audio_ms={u.units.get('audio_ms', 0)}" + ("" if not u.dry_run else f"; chars={u.units.get('chars', 0)}(추정 없음)")
            formula = "usageMetadata 실측 (input×input_per_1m + output×output_per_1m)/1e6×usd_krw"
            if cfg.get("gemini", {}).get("free_tier"):
                est = 0
            else:
                est = None if None in (pin, pout, fx) else to_krw((it * pin + ot * pout) / Decimal(10**6) * fx)
        elif u.provider == "gemini" and u.item == "video_script":
            g = p.get("gemini", {})
            pin, pout = dec(g.get("input_per_1m_tokens_usd", "")), dec(g.get("output_per_1m_tokens_usd", ""))
            it, ot, th = u.units["input_tokens"], u.units["output_tokens"], u.units.get("thinking_tokens", 0)
            usage = f"input_tokens={it}; output_tokens={ot}; thinking_tokens={th}(실측, usageMetadata)"
            formula = "usageMetadata 실측 (input×input_per_1m + (output+thinking)×output_per_1m)/1e6×usd_krw"
            if cfg.get("gemini", {}).get("free_tier"):
                est = 0
            else:  # 유료인데 단가·환율이 비면 est=None → billed 빈칸, note "단가 미상"
                est = None if None in (pin, pout, fx) else to_krw((it * pin + (ot + th) * pout) / Decimal(10**6) * fx)
        else:
            continue
        rows.append({"project": project, "provider": u.provider, "item": u.item, "usage": usage,
                     "formula": formula, "estimated_krw": "" if est is None else est,
                     "billed_krw": 0 if u.dry_run else ("" if est is None else est), "mode": "dry-run" if u.dry_run else "live",
                     "dry_run": "true" if u.dry_run else "false",
                     "note": "; ".join(x for x in (
                         f"model={u.note}" if u.note else "",
                         "단가 미상" if not u.dry_run and est is None else "",
                         "무료 구간: 학습 활용·사람 검토 대상" if u.note and cfg.get("gemini", {}).get("free_tier") else "") if x)})
    ph = dec(p["render_local"]["per_hour_krw"])
    est = None if ph is None else to_krw(Decimal(str(render_sec)) * ph / 3600)
    rows.append({"project": project, "provider": "render_local", "item": "ffmpeg", "usage": f"render_sec={render_sec:.2f}",
                 "formula": "render_sec×per_hour_krw/3600", "estimated_krw": "" if est is None else est,
                 "billed_krw": est or 0, "mode": "measured", "dry_run": "", "note": ""})
    total_est = [r["estimated_krw"] for r in rows]
    rows.append({"project": project, "provider": "TOTAL", "item": "", "usage": "", "formula": "합계",
                 "estimated_krw": sum(total_est) if all(x != "" for x in total_est) else "",
                 "billed_krw": sum(r["billed_krw"] for r in rows if r["billed_krw"] != ""), "mode": "", "dry_run": "",
                 "note": "단가 미상 행 제외" if any(r["billed_krw"] == "" for r in rows) else ""})
    return rows


def source_scenario(n: int, cuts: list[dict], sizes: list[tuple[int, int]], cfg: dict) -> tuple[list[dict], int, int]:
    """원본 n편 × 데모 컷 평균 길이: Claude 초당 1프레임 vs Gemini 영상. (행, claude 토큰, gemini 토큰)."""
    avg = sum(c["end"] - c["start"] for c in cuts) / len(cuts)
    frames = math.ceil(avg)
    c_tok = sum(ClaudeLLM.estimate_image_tokens(*sizes[(i * frames + k) % len(sizes)])
                for i in range(n) for k in range(frames))
    g_cfg = cfg.get("gemini", {})
    gu = GeminiVideo(True, int(g_cfg.get("tokens_per_frame", 70))).analyze(avg, n)
    g_tok, p, fx, proj = gu.units["input_tokens"], cfg["pricing"], dec(cfg.get("usd_krw", "")), f"sources_{n}"
    pc, pg = dec(p["claude"]["input_per_1m_tokens_usd"]), dec(p.get("gemini", {}).get("input_per_1m_tokens_usd", ""))
    c_est = None if None in (pc, fx) else to_krw(c_tok * pc / Decimal(10**6) * fx)
    free = bool(g_cfg.get("free_tier"))
    g_est = 0 if free else (None if None in (pg, fx) else to_krw(g_tok * pg / Decimal(10**6) * fx))
    e = lambda v: "" if v is None else v
    rows = [
        {"project": proj, "provider": "claude", "item": "source_frames",
         "usage": f"sources={n}; avg_sec={avg:.1f}; frames={n * frames}; input_tokens={c_tok}(추정)",
         "formula": "원본 n×ceil(평균초)프레임(초당1) ceil(w×h/750)합 ×input_per_1m/1e6×usd_krw",
         "estimated_krw": e(c_est), "billed_krw": 0, "mode": "dry-run", "dry_run": "true", "note": ""},
        {"project": proj, "provider": "gemini", "item": "video",
         "usage": f"sources={n}; seconds={gu.units['seconds']}; input_tokens={g_tok}(추정)",
         "formula": "ceil(초)×(tokens_per_frame+오디오32)×input_per_1m/1e6×usd_krw",
         "estimated_krw": e(g_est), "billed_krw": 0, "mode": "dry-run", "dry_run": "true",
         "note": "무료 구간: 학습 활용·사람 검토 대상" if free else ""},
        {"project": proj, "provider": "ALT_TOTAL(gemini)", "item": "", "usage": "", "formula": "gemini 영상 분석 합계(비교용, 기존 TOTAL과 별개)",
         "estimated_krw": e(g_est), "billed_krw": 0, "mode": "", "dry_run": "", "note": ""},
    ]
    return rows, c_tok, g_tok


THUMBS, THUMB_SIZE, GEMINI_IMG_TOKENS = 20, (720, 1280), 258
NO_PRICE = "단가 입력 전"
LIVE_PROMPT = ("첨부한 쇼핑 숏폼 원본 영상을 분석해 (1) 화면에 보이는 장면·동작을 컷 순서로 3줄 요약하고 "
               "(2) 원본에 보이는 동작만으로 한국어 쇼츠 대본 초안을 5문장 안팎으로 쓰세요. "
               "보이지 않는 효능·성능·수치를 지어내지 마세요.")


def estimate_table(cms: list[dict], n: int, cfg: dict) -> list[dict]:
    """렌더 전 영상 1편 기준 모델 조합별 예상 토큰·원(dry-run 추정, 호출 없음). config `estimate` 가정 우선, 없으면 첫 cut_map 기준."""
    cm, es = cms[0], cfg.get("estimate", {})
    prompt = "다음 대사를 쇼츠 대본으로 다듬어 주세요:\n" + "\n".join(c["line"] for c in cm["cuts"])
    s_in = s_out = ClaudeLLM.estimate_tokens(prompt)  # dry-run 출력 길이 ≈ 입력 길이
    s_in, s_out = int(es.get("script_input_tokens") or s_in), int(es.get("script_output_tokens") or s_out)
    avg = float(es.get("source_avg_sec") or sum(c["end"] - c["start"] for c in cm["cuts"]) / len(cm["cuts"]))
    frames = math.ceil(avg)
    srcs = sorted({c["source_path"] for c in cm["cuts"]})
    sizes = [tuple(es["source_frame"])] if es.get("source_frame") else [probe_video_size(x) for x in srcs]
    c_vid = sum(ClaudeLLM.estimate_image_tokens(*sizes[(i * frames + k) % len(sizes)]) for i in range(n) for k in range(frames))
    g_vid = GeminiVideo(True, int(cfg.get("gemini", {}).get("tokens_per_frame", 70))).analyze(avg, n).units["input_tokens"]
    c_th, g_th = THUMBS * ClaudeLLM.estimate_image_tokens(*THUMB_SIZE), THUMBS * GEMINI_IMG_TOKENS
    p, fx = cfg["pricing"], dec(cfg.get("usd_krw", ""))
    pr = {k: (dec(p.get(k, {}).get("input_per_1m_tokens_usd", "")), dec(p.get(k, {}).get("output_per_1m_tokens_usd", ""))) for k in ("claude", "gemini")}

    def krw(parts: list[tuple[str, int, int]]):
        usd = Decimal(0)
        for prov, tin, tout in parts:
            pi, po = pr[prov]
            if pi is None or fx is None or (tout and po is None):
                return NO_PRICE
            usd += (tin * pi + tout * po) / Decimal(10**6) if tout else tin * pi / Decimal(10**6)
        return to_krw(usd * fx)

    combos = [
        ("최저", "Gemini 대본+Gemini 영상", "gemini", g_th, g_vid, "gemini"),
        ("추천", "Claude 대본+Gemini 영상", "claude", g_th, g_vid, "gemini"),
        ("Claude만", "Claude 대본+Claude 프레임", "claude", c_th, c_vid, "claude"),
    ]
    rows = []
    for tag, name, sp, th, vid, vp in combos:
        rows.append({"combo": f"{tag}: {name}", "script_tokens": s_in + s_out, "thumb_tokens": th, "video_tokens": vid,
                     "total_tokens": s_in + s_out + th + vid,
                     "estimated_krw": krw([(sp, s_in, s_out), (vp, th + vid, 0)]), "note": f"원본 {n}편 · 썸네일 {THUMBS}장"})
    gt = p.get("gemini_tts", {})
    gpi, gpo = dec(gt.get("input_per_1m_tokens_usd", "")), dec(gt.get("output_per_1m_tokens_usd", ""))
    t_sec = cm["target_sec"]
    t_in, t_out = ClaudeLLM.estimate_tokens(" ".join(c["line"] for c in cm["cuts"])), t_sec * GeminiTTS.AUDIO_TOKENS_PER_SEC
    if cfg.get("gemini", {}).get("free_tier"):
        tk = 0
    else:
        tk = NO_PRICE if None in (gpi, gpo, fx) else to_krw((t_in * gpi + t_out * gpo) / Decimal(10**6) * fx)
    rows.append({"combo": "공통: 음성(테스트): Gemini TTS", "script_tokens": "", "thumb_tokens": "", "video_tokens": "",
                 "total_tokens": t_in + t_out, "estimated_krw": tk,
                 "note": f"모델 {cfg.get('gemini', {}).get('tts_model', '')} · 입력 {t_in}+오디오 {t_out}토큰(초당 25 추정)"})
    nb = len(" ".join(c["line"] for c in cm["cuts"]).encode("utf-8"))
    fish = dec(p["fish_audio"]["per_1m_units_usd"])
    fk = NO_PRICE if None in (fish, fx) else to_krw(nb * fish / Decimal(10**6) * fx)
    rows.append({"combo": "공통: 음성(Fish Audio)·렌더", "script_tokens": "", "thumb_tokens": "", "video_tokens": "",
                 "total_tokens": "", "estimated_krw": fk, "note": f"음성 {nb}바이트 · 렌더는 로컬 측정(렌더 후 원가 표)"})
    return rows


class FileTTS:
    """이미 있는 음성 파일을 TTS 결과로 쓴다(API 호출 없음, 비용 0)."""
    def __init__(self, path: Path):
        self.path = path

    def synthesize(self, text, voice_id, out_path):
        ff(["-i", str(self.path), out_path])
        return out_path, Usage("gemini_tts", "tts", {"chars": len(text), "utf8_bytes": len(text.encode("utf-8"))}, True)


def main() -> int:
    ap = argparse.ArgumentParser(description="대행 파이프라인 PoC")
    ap.add_argument("cut_maps", nargs="*", type=Path, help="cut_map JSON 경로")
    ap.add_argument("--demo", action="store_true", help="합성 클립으로 samples/demo_*.json 실행")
    ap.add_argument("--sources", type=int, default=10, help="원본 편수 시나리오(Claude 프레임 vs Gemini 영상)")
    ap.add_argument("--live", action="store_true", help="실제 API 호출(--llm gemini만 구현, 키는 .env.local)")
    ap.add_argument("--voice-samples", action="store_true", help="목소리 후보 샘플 4개 live 생성(out/listen/voice_<이름>.mp3)")
    ap.add_argument("--voice-file", type=Path, default=None, help="기존 음성 파일을 TTS 결과로 사용(첫 cut_map만, 호출 없음)")
    ap.add_argument("--tts", choices=["fish", "gemini"], default=None, help="음성(기본: --live면 gemini 테스트용, 아니면 fish dry-run). fish live는 미구현")
    ap.add_argument("--llm", choices=["claude", "gemini"], default="gemini", help="live 대본·영상 분석 모델(기본 gemini = 테스트용 Google API 키, claude는 미구현)")
    args = ap.parse_args()

    cfg = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))
    if args.voice_samples:
        make_voice_samples(cfg)
        return 0
    maps = list(args.cut_maps)
    if args.demo:
        make_demo_sources()
        maps += sorted((ROOT / "samples").glob("demo_*.json"))
    if not maps:
        ap.error("cut_map 경로 또는 --demo 가 필요합니다")

    live_gemini = args.live and args.llm == "gemini"
    gc = cfg.get("gemini", {})
    tts_kind = args.tts or ("gemini" if args.live else "fish")
    mk_tts = lambda dry: (GeminiTTS(dry, gc.get("tts_model", ""), gc.get("tts_voice", ""), gc.get("tts_style", ""), gc.get("tts_style_mode", "system")) if tts_kind == "gemini"
                          else FishAudioTTS(dry_run=dry))
    tts = mk_tts(not args.live)
    llm = ClaudeLLM(dry_run=not live_gemini and not args.live)  # --live --llm claude는 NotImplementedError 유지
    if live_gemini:
        llm = ClaudeLLM(dry_run=True)  # Claude 추정 행은 유지, 대본·영상은 Gemini 실호출
        tts = mk_tts(tts_kind != "gemini")  # fish는 dry-run 유지, gemini TTS는 실호출
    if args.voice_file:
        if args.live:
            ap.error("--voice-file은 --live와 함께 쓰지 않습니다")
        tts = FileTTS(args.voice_file)
    gemini = GeminiVideo(not live_gemini, int(cfg.get("gemini", {}).get("tokens_per_frame", 70)), cfg.get("gemini", {}).get("model", ""))
    all_rows, failures, all_cuts, all_sizes = [], 0, [], []
    cms = [load_cut_map(path) for path in maps]
    est = estimate_table(cms, args.sources, cfg)
    OUT.mkdir(parents=True, exist_ok=True)
    with (OUT / "estimate.csv").open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(est[0].keys()))
        w.writeheader()
        w.writerows(est)
    print("제작 전 AI 예상 비용(영상 1편 기준, dry-run 추정)")
    for r in est:
        print(f"  {r['combo']:<34} 토큰 {str(r['total_tokens']) or '-':>7}  예상 {r['estimated_krw']}{'' if r['estimated_krw'] == NO_PRICE else '원'}  ({r['note']})")
    print(f"예상 비용 표 → {OUT / 'estimate.csv'}")
    for idx, cm in enumerate(cms):
        print(f"[{cm['project']}] 컷 {len(cm['cuts'])}개, 목표 {cm['target_sec']}초")
        script_prompt = "다음 대사를 쇼츠 대본으로 다듬어 주세요:\n" + "\n".join(c["line"] for c in cm["cuts"])
        _, llm_usage = llm.complete(script_prompt)
        t0 = time.perf_counter()
        final, usages = render(cm, cfg, tts if idx == 0 else mk_tts(True))  # live 호출 최소화: 첫 cut_map만 실제 음성
        sizes = extract_frames(cm, cfg, final.parent)
        all_cuts += cm["cuts"]
        all_sizes += sizes
        vision_usage = llm.describe_frames(sizes)
        if live_gemini and idx == 0:  # 호출 수 최소화: 첫 cut_map(합성 컷 편집본)만 실제 전송
            print(f"  Gemini 실호출({gemini.model}): 원본 분석 + 대본 초안 …")
            tg = time.perf_counter()
            text, gu = gemini.analyze_script(str(final.parent / "video.mp4"), LIVE_PROMPT)
            (final.parent / "gemini_script.txt").write_text(text, encoding="utf-8")
            usages.append(gu)
            print(f"  대본 → {final.parent / 'gemini_script.txt'} (토큰 {gu.units})")
            t0 += time.perf_counter() - tg  # 렌더 시간에서 API 호출 시간 제외
        render_sec = time.perf_counter() - t0
        errs = verify(final, cm["target_sec"])
        tj = final.parent / "timing.json"
        if tj.is_file():
            timing = json.loads(tj.read_text(encoding="utf-8"))
            if timing["method"] != "char_ratio_dry":  # 실제 음성이 있을 때만 경계 검증
                errs += check_sync(final, timing)
                tj.write_text(json.dumps(timing, ensure_ascii=False, indent=2), encoding="utf-8")
        for e in errs:
            print(f"  실패: {e}")
        failures += bool(errs)
        all_rows += cost_rows(cm["project"], [vision_usage, llm_usage, *usages], render_sec, cfg)

    sc_rows, c_tok, g_tok = source_scenario(args.sources, all_cuts, all_sizes, cfg)
    all_rows += sc_rows
    print(f"원본 {args.sources}편 시나리오 토큰: claude 프레임 {c_tok} vs gemini 영상 {g_tok}")
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
