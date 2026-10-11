"""Run: python -m unittest discover -s tool/local_servers -p 'test_subtitle_translation.py'"""

import copy
import io
import json
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError

import subtitle_translation as mt


CONFIG = {"engine": "llm", "baseUrl": "https://example.test/v1",
          "apiKey": "test-key", "model": "selected-model",
          "translationGuide": "render → 渲染"}


def subtitles(count=15):
    return [{"start": i * 2.5, "end": i * 2.5 + 2,
             "text": f"source {i + 1}", "translation": ""} for i in range(count)]


def reply(config, messages):
    payload = json.loads(messages[1]["content"])
    # Return in reverse order to catch positional rather than ID-based matching.
    return json.dumps({"translations": [
        {"id": row["id"], "text": f"译文 {row['id']}"}
        for row in reversed(payload["subtitles"])]}, ensure_ascii=False)


class SubtitleTranslationTest(unittest.TestCase):
    def test_batches_include_both_contexts_and_preserve_alignment(self):
        items = subtitles()
        original = copy.deepcopy(items)
        progress = []
        with patch.object(mt, "_chat", side_effect=reply) as chat:
            mt.translate_subtitles(items, CONFIG, "ja", "zh", on_progress=progress.append)
        self.assertEqual(chat.call_count, 2)
        first = json.loads(chat.call_args_list[0].args[1][1]["content"])
        second = json.loads(chat.call_args_list[1].args[1][1]["content"])
        self.assertEqual(first["source_language"], "ja")
        self.assertEqual(first["following_context"], ["source 13", "source 14", "source 15"])
        self.assertEqual(len(second["previous_context"]), 6)
        self.assertEqual(second["previous_context"][-1],
                         {"original": "source 12", "translation": "译文 12"})
        self.assertIn("render → 渲染", chat.call_args_list[0].args[1][0]["content"])
        for i, item in enumerate(items):
            self.assertEqual(item["translation"], f"译文 {i + 1}")
            self.assertEqual({k: v for k, v in item.items() if k != "translation"},
                             {k: v for k, v in original[i].items() if k != "translation"})
        self.assertEqual(progress, [12 / 15, 1.0])

    def test_character_budget_splits_long_cues(self):
        items = subtitles(4)
        for item in items:
            item["text"] = "x" * 3000
        with patch.object(mt, "_chat", side_effect=reply) as chat:
            mt.translate_subtitles(items, CONFIG, None, "zh")
        self.assertEqual(chat.call_count, 4)
        for call in chat.call_args_list:
            data = json.loads(call.args[1][1]["content"])
            self.assertLessEqual(sum(len(s) for s in data["following_context"]), 2000)

    def test_invalid_output_retries_without_applying_partial_translations(self):
        items = subtitles(2)
        with patch.object(mt, "_chat", side_effect=[
            '{"translations":[{"id":1,"text":"部分译文"}]}',
            '{"translations":[{"id":1,"text":"一"},{"id":2,"text":"二"}]}',
        ]) as chat:
            mt.translate_subtitles(items, CONFIG, None, "zh")
        self.assertEqual(chat.call_count, 2)
        self.assertEqual([it["translation"] for it in items], ["一", "二"])

    def test_invalid_output_fails_instead_of_copying_source(self):
        items = subtitles(2)
        with patch.object(mt, "_chat", return_value='{"translations":[]}') as chat:
            with self.assertRaisesRegex(mt.TranslationError, "校验失败"):
                mt.translate_subtitles(items, CONFIG, None, "zh")
        self.assertEqual(chat.call_count, 2)
        self.assertEqual([it["translation"] for it in items], ["", ""])

    def test_rejects_duplicate_missing_unknown_empty_or_wrong_type_ids(self):
        invalid = [
            [{"id": 1, "text": "一"}, {"id": 1, "text": "重复"}],
            [{"id": 2, "text": "二"}], [{"id": 1, "text": " "}],
            [{"id": "1", "text": "一"}], [{"id": True, "text": "一"}],
            [{"id": 1, "text": None}], [], None,
        ]
        for rows in invalid:
            with self.subTest(rows=rows), self.assertRaises(mt.TranslationError):
                mt._parse_translation(json.dumps({"translations": rows}), [1])

    def test_fences_and_blank_lines_are_safe_for_srt(self):
        content = '```json\n{"translations":[{"id":1,"text":"一\\n\\n二"}]}\n```'
        self.assertEqual(mt._parse_translation(content, [1]), {1: "一\n二"})

    def test_legacy_and_explicit_local_translation(self):
        for config in (None, {"engine": "nllb_local"}):
            local = Mock(return_value="译文")
            items = subtitles(1)
            with patch.object(mt, "_chat") as chat:
                mt.translate_subtitles(items, config, "ja", "zh", local_translate=local)
            local.assert_called_once_with("source 1", "ja", "zh")
            chat.assert_not_called()
            self.assertEqual(items[0]["translation"], "译文")

    def test_local_inference_failure_is_not_swallowed(self):
        items = subtitles(1)
        with self.assertRaisesRegex(RuntimeError, "model failed"):
            mt.translate_subtitles(items, None, None, "zh",
                                   local_translate=Mock(side_effect=RuntimeError("model failed")))
        self.assertEqual(items[0]["translation"], "")

    def test_empty_local_translation_retries_then_continues(self):
        for empty in ("", " \n\t", None):
            for config in (None, {"engine": "nllb_local"}):
                with self.subTest(empty=empty, config=config):
                    items = subtitles(93)
                    progress, warnings = [], []
                    local = Mock(side_effect=lambda text, *_:
                                 empty if text == "source 91" else "译文 " + text)
                    mt.translate_subtitles(
                        items, config, "ja", "zh", local_translate=local,
                        on_progress=progress.append,
                        on_warning=lambda index, reason: warnings.append((index, reason)))
                    self.assertEqual(local.call_count, 94)
                    self.assertEqual(items[90]["translation"], "source 91")
                    self.assertEqual(items[91]["translation"], "译文 source 92")
                    self.assertEqual(items[92]["translation"], "译文 source 93")
                    self.assertEqual(len(progress), 93)
                    self.assertEqual(progress[-1], 1)
                    self.assertEqual(len(warnings), 1)
                    self.assertEqual(warnings[0][0], 91)
                    self.assertIn("保留原文", warnings[0][1])

    def test_local_retry_recovery_does_not_warn(self):
        items = subtitles(2)
        local = Mock(side_effect=["", "重试成功", "下一条译文"])
        warning = Mock()
        mt.translate_subtitles(items, None, None, "zh", local_translate=local,
                               on_warning=warning)
        self.assertEqual([item["translation"] for item in items], ["重试成功", "下一条译文"])
        warning.assert_not_called()

    def test_all_empty_local_results_preserve_every_cue(self):
        items = subtitles(3)
        warning = Mock()
        mt.translate_subtitles(items, None, None, "zh", local_translate=Mock(return_value=""),
                               on_warning=warning)
        self.assertEqual([item["translation"] for item in items],
                         [item["text"] for item in items])
        self.assertEqual([call.args[0] for call in warning.call_args_list], [1, 2, 3])

    def test_selected_model_key_and_thinking_are_sent(self):
        for base in ("https://api.deepseek.com/v1", "https://example.test/v1"):
            config = dict(CONFIG, baseUrl=base, thinking=True, thinkingEffort="high")
            response = Mock()
            response.__enter__ = Mock(return_value=response)
            response.__exit__ = Mock(return_value=False)
            response.read.return_value = json.dumps({"choices": [
                {"message": {"content": "译文"}, "finish_reason": "stop"}]}).encode()
            with patch.object(mt, "urlopen", return_value=response) as post:
                self.assertEqual(mt._chat(config, []), "译文")
            req = post.call_args.args[0]
            body = json.loads(req.data)
            self.assertEqual(req.full_url, base + "/chat/completions")
            self.assertEqual(req.get_header("Authorization"), "Bearer test-key")
            self.assertEqual(body["model"], "selected-model")
            if "deepseek" in base:
                self.assertEqual(body["thinking"], {"type": "enabled"})
                self.assertNotIn("temperature", body)
            else:
                self.assertNotIn("thinking", body)

    def test_auth_error_hides_response_and_does_not_retry(self):
        error = HTTPError(CONFIG["baseUrl"], 401, "secret", {}, io.BytesIO(b"test-key"))
        with patch.object(mt, "urlopen", side_effect=error) as post:
            with self.assertRaises(mt.TranslationError) as caught:
                mt._chat(CONFIG, [])
        self.assertIn("401", str(caught.exception))
        self.assertNotIn("test-key", str(caught.exception))
        self.assertEqual(post.call_count, 1)

    def test_network_error_retries_once(self):
        with patch.object(mt, "urlopen", side_effect=URLError("offline")) as post, \
                patch.object(mt.time, "sleep"):
            with self.assertRaisesRegex(mt.TranslationError, "网络"):
                mt._chat(CONFIG, [])
        self.assertEqual(post.call_count, 2)

    def test_empty_or_truncated_model_response_fails(self):
        for content, finish in ((" ", "stop"), ("partial", "length")):
            response = Mock()
            response.__enter__ = Mock(return_value=response)
            response.__exit__ = Mock(return_value=False)
            response.read.return_value = json.dumps({"choices": [
                {"message": {"content": content}, "finish_reason": finish}]}).encode()
            with patch.object(mt, "urlopen", return_value=response):
                with self.assertRaises(mt.TranslationError):
                    mt._chat(CONFIG, [])

    def test_invalid_config_does_not_fall_back_to_local(self):
        for config in ({"engine": "unknown"}, dict(CONFIG, baseUrl=""), dict(CONFIG, model="")):
            with self.assertRaises(mt.TranslationError):
                mt.translate_subtitles(subtitles(1), config, None, "zh")


if __name__ == "__main__":
    unittest.main()
