"""Tests for tools/import_litellm.py.  Run: python tools/test_import_litellm.py"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import import_litellm as il  # noqa: E402

SAMPLE = """\
# a typical LiteLLM proxy config
model_list:
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/OPENAI_API_KEY   # from the environment
      timeout: 30
    model_info:
      input_cost_per_token: 0.0000025
      output_cost_per_token: 0.00001
  - model_name: gpt-4o
    litellm_params:
      model: openrouter/openai/gpt-4o
      api_key: os.environ/OPENROUTER_API_KEY
  - model_name: claude
    litellm_params:
      model: anthropic/claude-sonnet-5-5
      api_key: "sk-ant-literal-secret"
  - model_name: local
    litellm_params:
      model: openai/qwen3
      api_base: http://10.0.0.5:8000/v1
      api_key: none
  - model_name: azure-gpt
    litellm_params:
      model: azure/my-deployment
      api_base: https://example.openai.azure.com
      api_version: "2024-02-01"
  - model_name: bare
    litellm_params: {model: gpt-4o-mini}
  - model_name: flash
    litellm_params:
      model: gemini/gemini-3.5-flash
      api_key: os.environ/GEMINI_API_KEY

router_settings:
  fallbacks: [{"gpt-4o": ["claude"]}, {"claude": ["missing"]}]
  num_retries: 2

general_settings:
  master_key: sk-1234
"""


class MiniYaml(unittest.TestCase):
    def test_structures(self):
        doc = il.parse_yaml("""\
a: 1
b:
  c: [1, "two", {x: y}]
  d: 'q: r'
e:
- p
- q: 1
  r: 2.5
- - nested
f: true
g: ~
h: "has # hash"   # comment
""")
        self.assertEqual(doc, {
            "a": 1,
            "b": {"c": [1, "two", {"x": "y"}], "d": "q: r"},
            "e": ["p", {"q": 1, "r": 2.5}, ["nested"]],
            "f": True,
            "g": None,
            "h": "has # hash",
        })

    def test_rejects_what_it_cannot_parse(self):
        with self.assertRaises(il.YamlError):
            il.parse_yaml("a: |\n  block text\n")
        with self.assertRaises(il.YamlError):
            il.parse_yaml("a: &anchor 1\n")


class Convert(unittest.TestCase):
    def setUp(self):
        self.config, self.report = il.convert(il.parse_yaml(SAMPLE))
        self.routes = {r["model"]: r["targets"] for r in self.config["routes"]}
        self.upstreams = {u["name"]: u for u in self.config["upstreams"]}

    def test_same_model_name_becomes_ordered_failover(self):
        targets = self.routes["gpt-4o"]
        self.assertEqual([t["upstream"] for t in targets[:2]], ["openai", "openrouter"])
        self.assertEqual(targets[1]["model"], "openai/gpt-4o")

    def test_fallbacks_are_appended(self):
        self.assertEqual(self.routes["gpt-4o"][2], self.routes["claude"][0])
        self.assertTrue(any("missing" in n for n in self.report["notes"]))

    def test_prices_and_timeout(self):
        first = self.routes["gpt-4o"][0]
        self.assertAlmostEqual(first["price_in_per_mtok"], 2.5)
        self.assertAlmostEqual(first["price_out_per_mtok"], 10.0)
        self.assertEqual(self.upstreams["openai"]["timeout_ms"], 30000)

    def test_a_timeout_above_one_hour_is_cut_and_reported(self):
        config, report = il.convert({"model_list": [
            {"model_name": "slow", "litellm_params": {"model": "openai/gpt-4o", "timeout": 7200}},
            {"model_name": "edge", "litellm_params": {"model": "openai/gpt-4o-mini", "request_timeout": 3600}},
        ]})
        self.assertEqual(sorted(u["timeout_ms"] for u in config["upstreams"]), [3_600_000])
        self.assertEqual(len([n for n in report["notes"] if "7200 s" in n and "3600000 ms" in n]), 1)

    def test_upstream_shapes(self):
        self.assertEqual(self.upstreams["anthropic"]["kind"], "anthropic")
        self.assertEqual(self.upstreams["openrouter"]["base_url"], "https://openrouter.ai/api")
        local = self.upstreams[self.routes["local"][0]["upstream"]]
        self.assertEqual(local["base_url"], "http://10.0.0.5:8000")  # trailing /v1 dropped

    def test_literal_secrets_are_never_copied(self):
        self.assertNotIn("sk-ant-literal-secret", str(self.config))
        self.assertNotIn("sk-1234", str(self.config))
        self.assertEqual(self.upstreams["anthropic"]["api_key_env"], "ANTHROPIC_API_KEY")
        self.assertIn("NOT copied", self.report["env"]["ANTHROPIC_API_KEY"])

    def test_unsupported_provider_is_reported_not_guessed(self):
        self.assertNotIn("azure-gpt", self.routes)
        self.assertTrue(any(name == "azure-gpt" for name, _ in self.report["skipped"]))

    def test_gemini_uses_its_openai_compatible_path(self):
        up = self.upstreams[self.routes["flash"][0]["upstream"]]
        self.assertEqual(up["kind"], "openai")
        self.assertEqual(up["base_url"], "https://generativelanguage.googleapis.com")
        self.assertEqual(up["v1_path"], "/v1beta/openai")
        self.assertEqual(self.routes["flash"][0]["model"], "gemini-3.5-flash")

    def test_bare_model_names_default_to_openai(self):
        self.assertEqual(self.routes["bare"][0], {
            "upstream": "openai-2", "model": "gpt-4o-mini",
            "price_in_per_mtok": 0.0, "price_out_per_mtok": 0.0,
        })


if __name__ == "__main__":
    unittest.main()
