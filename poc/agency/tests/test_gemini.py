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


if __name__ == "__main__":
    unittest.main()
