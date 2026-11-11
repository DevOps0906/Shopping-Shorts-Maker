"""Gemini 어댑터 mock 테스트(네트워크 없음): python -m unittest discover poc/agency/tests"""
import io
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import adapters  # noqa: E402

KEY = "SECRET-KEY-VALUE-123"


def video(n=10) -> str:
    f = tempfile.NamedTemporaryFile(suffix=".mp4", delete=False)
    f.write(b"x" * n)
    f.close()
    return f.name


class GeminiTest(unittest.TestCase):
    def setUp(self):
        for p in (mock.patch.object(adapters, "load_gemini_key", return_value=KEY),
                  mock.patch.object(adapters.time, "sleep")):
            p.start()
            self.addCleanup(p.stop)

    def live(self):
        return adapters.GeminiVideo(False, model="m")

    def test_post_timeout_no_retry(self):
        with mock.patch("urllib.request.urlopen", side_effect=TimeoutError()) as u:
            with self.assertRaises(RuntimeError):
                self.live().analyze_script(video(), "p")
        self.assertEqual(u.call_count, 1)

    def test_429_retries_once(self):
        err = urllib.error.HTTPError("u", 429, "x", {}, io.BytesIO(b"{}"))
        with mock.patch("urllib.request.urlopen", side_effect=err) as u:
            with self.assertRaises(RuntimeError):
                self.live().analyze_script(video(), "p")
        self.assertEqual(u.call_count, 2)

    def test_dry_run_no_network(self):
        with mock.patch("urllib.request.urlopen") as u:
            with self.assertRaises(RuntimeError):
                adapters.GeminiVideo(model="m").analyze_script(video(), "p")
        u.assert_not_called()

    def test_body_over_20mb_rejected(self):
        with mock.patch("urllib.request.urlopen") as u:
            with self.assertRaises(RuntimeError):
                self.live().analyze_script(video(adapters.MAX_INLINE_BYTES * 3 // 4), "p")  # base64 후 20MB 초과
        u.assert_not_called()

    def test_key_not_in_error(self):
        errs = [TimeoutError(), urllib.error.URLError("boom"),
                urllib.error.HTTPError("u", 500, "x", {}, io.BytesIO(b"{}"))]
        for e in errs:
            with mock.patch("urllib.request.urlopen", side_effect=e):
                with self.assertRaises(RuntimeError) as cm:
                    self.live().analyze_script(video(), "p")
            self.assertNotIn(KEY, str(cm.exception))

    def test_tts_dry_run_no_network(self):
        with mock.patch("urllib.request.urlopen") as u:
            path, usage = adapters.GeminiTTS(model="m", voice="v").synthesize("안녕", "", "x.wav")
        u.assert_not_called()
        self.assertIsNone(path)
        self.assertTrue(usage.dry_run)

    def test_tts_style_prefix(self):
        import base64, json
        resp = {"candidates": [{"content": {"parts": [{"inlineData": {"data": base64.b64encode(b"ab" * 10).decode(), "mimeType": "audio/L16;rate=24000"}}]}}]}
        with mock.patch.object(adapters, "gemini_request", return_value=resp) as g, mock.patch("wave.open"):
            adapters.GeminiTTS(False, "m", "v", "스타일:", "prefix").synthesize("대본", "", "x.wav")
        self.assertEqual(g.call_args[0][1]["contents"][0]["parts"][0]["text"], "스타일:\n대본")


class SyncPlanTest(unittest.TestCase):
    def test_plan_dry_run_sums_to_target(self):
        import run
        durs, tempo = run.plan_cuts(["가나다", "라마바사아자"], 15, None)
        self.assertAlmostEqual(sum(durs), 15, places=2)
        self.assertEqual(tempo, 1.0)
        self.assertLess(durs[0], durs[1])

    def test_plan_tempo_limits(self):
        import run
        _, slow = run.plan_cuts(["a", "b"], 15, [(0, 3), (3, 6)])  # 짧은 음성 → 0.9 (하한)
        _, fast = run.plan_cuts(["a", "b"], 15, [(0, 10), (10, 20)])  # 긴 음성 → 1.15 (상한)
        self.assertEqual(slow, 0.9)
        self.assertEqual(fast, 1.15)


if __name__ == "__main__":
    unittest.main()
