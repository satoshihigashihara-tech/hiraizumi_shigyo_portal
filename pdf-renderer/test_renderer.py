import copy
import json
import os
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import renderer
import worker


class RendererContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.job = json.loads((renderer.ROOT / "fixtures/max-input-job.json").read_text(encoding="utf-8"))
        cls.settings = json.loads(renderer.MANIFEST_PATH.read_text(encoding="utf-8"))

    def test_fixture_hits_every_capacity(self):
        snapshot = self.job["source_snapshot"]
        for field in ("user_name", "user_address", "user_phone", "emergency_name", "emergency_address", "emergency_phone", "purpose", "special_notes"):
            self.assertEqual(len(snapshot[field]), self.settings["field_limits"][field])
        self.assertEqual(len(self.job["render_context"]["room_name"]), self.settings["field_limits"]["room_name"])

    def test_over_capacity_is_rejected_before_conversion(self):
        job = copy.deepcopy(self.job)
        job["source_snapshot"]["purpose"] += "超"
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(renderer.RenderError, "invalid-purpose"):
                renderer.merge_docx(job, self.settings, Path(directory) / "rejected.docx")

    def test_context_mismatch_is_rejected(self):
        job = copy.deepcopy(self.job)
        job["render_context"]["mayor_name"] = "改変"
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(renderer.RenderError, "context-mismatch"):
                renderer.merge_docx(job, self.settings, Path(directory) / "rejected.docx")

    def test_merge_preserves_every_opaque_package_part(self):
        template = renderer.ROOT / self.settings["template_path"]
        with tempfile.TemporaryDirectory() as directory:
            merged = Path(directory) / "merged.docx"
            renderer.merge_docx(self.job, self.settings, merged)
            with zipfile.ZipFile(template) as before, zipfile.ZipFile(merged) as after:
                self.assertEqual(before.namelist(), after.namelist())
                for name in before.namelist():
                    if name not in {"word/document.xml", "word/styles.xml", "docProps/core.xml"}:
                        self.assertEqual(before.read(name), after.read(name), name)

    def test_initial_and_preapproval_form_strikes_change_word_only(self):
        with tempfile.TemporaryDirectory() as directory:
            merged = Path(directory) / "merged.docx"
            renderer.merge_docx(self.job, self.settings, merged)
            with zipfile.ZipFile(merged) as package:
                document = renderer.ET.fromstring(package.read("word/document.xml"))
                struck = [
                    "".join(node.text or "" for node in run.findall(f"{renderer.W}t"))
                    for run in document.findall(f".//{renderer.W}r")
                    if run.find(f"{renderer.W}rPr/{renderer.W}strike") is not None
                ]
                self.assertEqual(struck, ["（変更）", "（変更）"])

    def test_approved_change_keeps_change_word_visible(self):
        job = copy.deepcopy(self.job)
        job["source_snapshot"]["previously_approved"] = True
        with tempfile.TemporaryDirectory() as directory:
            merged = Path(directory) / "merged.docx"
            renderer.merge_docx(job, self.settings, merged)
            with zipfile.ZipFile(merged) as package:
                document = package.read("word/document.xml")
                self.assertNotIn(b"<w:strike", document)

    def test_irrelevant_source_metadata_is_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            merged = Path(directory) / "merged.docx"
            renderer.merge_docx(self.job, self.settings, merged)
            with zipfile.ZipFile(merged) as package:
                core = package.read("docProps/core.xml").decode("utf-8")
                self.assertNotIn("通勤手当", core)
                self.assertNotIn("鈴木麻友子", core)

    def test_wareki_boundaries(self):
        self.assertEqual(renderer.wareki(renderer.date(2019, 5, 1)), "令和1年5月1日")
        self.assertEqual(renderer.wareki(renderer.date(1989, 1, 8)), "平成1年1月8日")
        with self.assertRaisesRegex(renderer.RenderError, "unsupported-era"):
            renderer.wareki(renderer.date(1989, 1, 7))

    def test_runtime_image_must_be_an_immutable_digest(self):
        previous = os.environ.get("CAMP_PDF_CONVERTER_IMAGE")
        os.environ["CAMP_PDF_CONVERTER_IMAGE"] = "ghcr.io/example/camp-pdf-renderer:latest"
        try:
            with self.assertRaisesRegex(renderer.RenderError, "invalid-converter-image"):
                renderer.runtime_settings()
        finally:
            if previous is None:
                os.environ.pop("CAMP_PDF_CONVERTER_IMAGE", None)
            else:
                os.environ["CAMP_PDF_CONVERTER_IMAGE"] = previous


class WorkerContractTests(unittest.TestCase):
    def setUp(self):
        self.environment = mock.patch.dict(os.environ, {
            "CAMP_PDF_WORKER_URL": "https://example.invalid/camp-pdf-worker",
            "CAMP_PDF_WORKER_SECRET": "a8-test-secret-" * 3,
            "CAMP_PDF_CONVERTER_IMAGE": "ghcr.io/example/camp-pdf-renderer@sha256:" + "a" * 64,
        })
        self.environment.start()

    def tearDown(self):
        self.environment.stop()

    @staticmethod
    def claim():
        return {
            "job_id": "11111111-1111-4111-8111-111111111111",
            "attempt_id": "22222222-2222-4222-8222-222222222222",
            "source_hash": "a" * 64,
        }

    def test_uncertain_completion_never_sends_fail(self):
        calls = []

        def fake_post(_endpoint, _secret, payload):
            calls.append(payload["operation"])
            if payload["operation"] == "claim":
                return self.claim()
            raise OSError("lost response")

        def fake_render(_job, output, _docx, _qa):
            output.write_bytes(b"%PDF-1.7\n%%EOF\n")
            return {"page_count": 1, "fonts_embedded": True, "text_verified": True, "layout_verified": True}

        with mock.patch.object(worker, "post", side_effect=fake_post), mock.patch.object(worker, "render", side_effect=fake_render):
            with self.assertRaisesRegex(OSError, "lost response"):
                worker.main()
        self.assertEqual(calls, ["claim", "complete"])

    def test_generation_failure_sends_one_fail(self):
        calls = []

        def fake_post(_endpoint, _secret, payload):
            calls.append(payload["operation"])
            return self.claim() if payload["operation"] == "claim" else {"recorded": True}

        with mock.patch.object(worker, "post", side_effect=fake_post), mock.patch.object(worker, "render", side_effect=renderer.RenderError("failed")):
            with self.assertRaisesRegex(renderer.RenderError, "failed"):
                worker.main()
        self.assertEqual(calls, ["claim", "fail"])


if __name__ == "__main__":
    unittest.main()
