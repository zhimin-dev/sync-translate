"""Batch API integration tests (FastAPI dependencies, no Whisper/NLLB weights).

Run: python -m unittest discover -s tool/local_servers -p 'test_*translation.py'
"""

import importlib
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

from fastapi.testclient import TestClient
import numpy as np

import subtitle_translation as mt
from test_subtitle_translation import CONFIG, reply, subtitles


class BatchTranslationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Stub only the heavyweight inference import; exercise real API/parser/writer.
        whisper = types.ModuleType("faster_whisper")
        whisper.WhisperModel = Mock()
        with patch.dict(sys.modules, {"faster_whisper": whisper}):
            cls.server = importlib.import_module("whisper_server")
        cls.client = TestClient(cls.server.app)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name) / "sample.srt"
        self.source.write_text(
            '\ufeff1\n00:00:01,250 --> 00:00:03,500\nFirst line\ncontinued\n\n'
            '2\n00:00:05,000 --> 00:00:07,100\nSecond line\n', encoding="utf-8")
        self.server.BATCH_JOBS.clear()

    def submit(self, translator=CONFIG, endpoint="translate-srt"):
        data = {"path": str(self.source), "target_lang": "zh", "source_lang": "ja"}
        if translator is not None:
            data["translator"] = translator
        with patch.object(self.server, "_kick_worker"):
            response = self.client.post("/batch/" + endpoint, json=data)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()["job_id"]

    def test_srt_uses_selected_llm_and_retains_timing_and_original(self):
        original = self.source.read_bytes()
        job_id = self.submit()
        with patch.object(mt, "_chat", side_effect=reply), \
                patch.object(self.server, "_ensure_nllb") as local:
            self.server._batch_worker()
        local.assert_not_called()
        job = self.client.get("/batch/status", params={"job_id": job_id}).json()
        self.assertEqual(job["status"], "完成")
        self.assertEqual(job["progress"], 1)
        output = Path(job["srt_path"]).read_text(encoding="utf-8")
        self.assertIn("00:00:01,250 --> 00:00:03,500\n译文 1", output)
        self.assertIn("00:00:05,000 --> 00:00:07,100\n译文 2", output)
        self.assertEqual(self.source.read_bytes(), original)
        self.assertNotIn("_translator", self.server.BATCH_JOBS[job_id])

    def test_credentials_hidden_while_queued_for_both_endpoints(self):
        for endpoint in ("translate-srt", "transcribe"):
            job_id = self.submit(endpoint=endpoint)
            self.assertEqual(self.server.BATCH_JOBS[job_id]["_translator"]["model"],
                             "selected-model")
            for response in (
                self.client.get("/batch/status", params={"job_id": job_id}),
                self.client.get("/batch/jobs"),
            ):
                self.assertNotIn("test-key", response.text)
                self.assertNotIn("_translator", response.text)

    def test_translation_failure_does_not_generate_fake_output(self):
        job_id = self.submit()
        with patch.object(mt, "_chat", return_value='{"translations":[]}'):
            self.server._batch_worker()
        job = self.server.BATCH_JOBS[job_id]
        self.assertEqual(job["status"], "失败")
        self.assertNotIn("srt_path", job)
        self.assertNotIn("_translator", job)
        self.assertFalse(self.source.with_suffix(".zh.srt").exists())

    def test_video_preserves_transcript_on_failure_and_uses_detected_language(self):
        self.source = self.source.with_suffix(".mp4")
        self.source.touch()
        job_id = self.submit(endpoint="transcribe")
        job = self.server.BATCH_JOBS[job_id]
        job["source_lang"] = "auto"
        model = Mock()
        model.transcribe.return_value = (
            [types.SimpleNamespace(start=0.25, end=1.5, text="元の字幕", words=[])],
            types.SimpleNamespace(language="ja"))
        with patch.object(self.server, "_model", model), \
                patch.object(self.server, "_decode_audio", return_value=np.zeros(32000)), \
                patch.object(self.server, "_media_duration", return_value=2), \
                patch.object(mt, "_chat", side_effect=mt.TranslationError("offline")) as chat:
            self.server._batch_worker()
        self.assertEqual(job["status"], "失败")
        self.assertIn("元の字幕", Path(job["orig_srt_path"]).read_text(encoding="utf-8"))
        self.assertNotIn("srt_path", job)
        self.assertEqual(json.loads(chat.call_args.args[1][1]["content"])["source_language"], "ja")
        self.assertIsNone(model.transcribe.call_args.kwargs["language"])

    def test_legacy_request_still_uses_nllb(self):
        job_id = self.submit(translator=None)
        local_module = types.ModuleType("nllb_server")
        local_module.translate_text = Mock(return_value="本地译文")
        with patch.dict(sys.modules, {"nllb_server": local_module}), \
                patch.object(self.server, "_ensure_nllb") as ensure:
            self.server._batch_worker()
        ensure.assert_called_once()
        self.assertEqual(self.server.BATCH_JOBS[job_id]["status"], "完成")
        self.assertEqual(local_module.translate_text.call_count, 2)
        self.assertEqual(local_module.translate_text.call_args.args[1:], ("ja", "zh"))

    def test_invalid_llm_config_is_rejected_before_queueing(self):
        response = self.client.post("/batch/translate-srt", json={
            "path": str(self.source), "translator": dict(CONFIG, model="")})
        self.assertEqual(response.status_code, 400)
        self.assertEqual(self.server.BATCH_JOBS, {})

    def test_empty_91st_cue_exports_complete_srt_with_warning(self):
        entries = subtitles(93)
        self.source.write_text(self.server._to_srt(entries, "text"), encoding="utf-8")
        original = self.source.read_bytes()
        job_id = self.submit(translator={"engine": "nllb_local"})
        local_module = types.ModuleType("nllb_server")
        local_module.translate_text = Mock(side_effect=lambda text, *_:
                                           "" if text == "source 91" else "译文 " + text)
        with patch.dict(sys.modules, {"nllb_server": local_module}), \
                patch.object(self.server, "_ensure_nllb"):
            self.server._batch_worker()
        job = self.client.get("/batch/status", params={"job_id": job_id}).json()
        self.assertEqual(job["status"], "完成")
        self.assertEqual(job["progress"], 1)
        self.assertNotIn("error", job)
        self.assertEqual(job["untranslated_indices"], [91])
        self.assertEqual(job["warning_count"], 1)
        self.assertIn("第 91 条", job["warning"])
        translated = self.server._parse_srt(Path(job["srt_path"]).read_text(encoding="utf-8"))
        self.assertEqual(len(translated), 93)
        self.assertEqual(translated[90]["text"], "source 91")
        self.assertEqual(translated[91]["text"], "译文 source 92")
        self.assertEqual(translated[92]["text"], "译文 source 93")
        self.assertEqual([(row["start"], row["end"]) for row in translated],
                         [(row["start"], row["end"]) for row in entries])
        self.assertEqual(self.source.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
