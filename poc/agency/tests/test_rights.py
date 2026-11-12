"""권리 근거 검사(D7 출처 표기 경로) 테스트: python -m unittest discover poc/agency/tests"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run  # noqa: E402


def cut(**kw) -> dict:
    c = {"no": 1, "rights_basis": "attribution", "author": "a", "platform": "tiktok", "url": "https://example.com/v/1"}
    c.update(kw)
    return c


class RightsTest(unittest.TestCase):
    def test_attribution_with_ack_passes_without_seller_reply(self):
        run.check_rights({"notice_ack": True, "cuts": [cut()]})

    def test_attribution_requires_notice_ack(self):
        with self.assertRaisesRegex(ValueError, "notice_ack"):
            run.check_rights({"cuts": [cut()]})

    def test_attribution_requires_source_fields(self):
        with self.assertRaisesRegex(ValueError, "url"):
            run.check_rights({"notice_ack": True, "cuts": [cut(url="")]})

    def test_attribution_blocks_watermark_removal(self):
        with self.assertRaisesRegex(ValueError, "워터마크"):
            run.check_rights({"notice_ack": True, "cuts": [cut(remove_watermark=True)]})

    def test_missing_rights_basis_rejected(self):
        with self.assertRaisesRegex(ValueError, "rights_basis"):
            run.check_rights({"cuts": [{"no": 1}]})

    def test_confirmed_source_needs_no_ack(self):
        run.check_rights({"cuts": [{"no": 1, "rights_basis": "seller"}]})


if __name__ == "__main__":
    unittest.main()
