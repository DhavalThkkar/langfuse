import importlib.util
import pathlib
import sys
import unittest


SCRIPT_PATH = (
    pathlib.Path(__file__).resolve().parents[1] / "langfuse_feature_smoke_test.py"
)
SPEC = importlib.util.spec_from_file_location("langfuse_feature_smoke_test", SCRIPT_PATH)
smoke = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = smoke
SPEC.loader.exec_module(smoke)


class LangfuseFeatureSmokeTestHelpers(unittest.TestCase):
    def test_normalize_base_url_accepts_http_and_https_only(self):
        self.assertEqual(
            smoke.normalize_base_url("https://cloud.langfuse.com/"),
            "https://cloud.langfuse.com",
        )
        self.assertEqual(
            smoke.normalize_base_url("http://localhost:3000/"),
            "http://localhost:3000",
        )

        with self.assertRaisesRegex(ValueError, "http or https"):
            smoke.normalize_base_url("file:///tmp/langfuse")

    def test_normalize_base_url_rejects_credentials_in_url(self):
        with self.assertRaisesRegex(ValueError, "must not include credentials"):
            smoke.normalize_base_url("https://user:pass@cloud.langfuse.com")

    def test_build_api_url_encodes_query_parameters(self):
        url = smoke.build_api_url(
            "https://cloud.langfuse.com/",
            "/api/public/traces/trace-1",
            {"fields": "core,io", "name": "hello world"},
        )

        self.assertEqual(
            url,
            "https://cloud.langfuse.com/api/public/traces/trace-1?fields=core%2Cio&name=hello+world",
        )

    def test_redact_hides_secrets_but_keeps_key_shape(self):
        self.assertEqual(smoke.redact("sk-lf-1234567890abcdef"), "sk-l...cdef")
        self.assertEqual(smoke.redact("short"), "***")

    def test_summarize_results_fails_when_required_check_fails(self):
        results = [
            smoke.CheckResult("health", True, "ok"),
            smoke.CheckResult("tracing", False, "missing trace"),
            smoke.CheckResult("scim", False, "not configured", optional=True),
        ]

        self.assertEqual(smoke.exit_code_for_results(results), 1)

    def test_summarize_results_ignores_optional_failures(self):
        results = [
            smoke.CheckResult("health", True, "ok"),
            smoke.CheckResult("scim", False, "not configured", optional=True),
        ]

        self.assertEqual(smoke.exit_code_for_results(results), 0)

    def test_wait_until_times_out(self):
        attempts = []

        result = smoke.wait_until(
            lambda: attempts.append(1) or None,
            timeout_seconds=0,
            interval_seconds=0,
        )

        self.assertIsNone(result)
        self.assertEqual(len(attempts), 1)

    def test_check_datasets_waits_for_run_item_trace_link(self):
        config = smoke.Config(
            public_key="pk-lf-test",
            secret_key="sk-lf-test",
            base_url="http://localhost:3000",
            prefix="unit",
            cleanup=False,
            poll_timeout_seconds=1,
            poll_interval_seconds=0,
            verbose=False,
        )
        tester = smoke.LangfuseSmokeTester(config)
        tester.trace_id = "trace-1"

        run_responses = [
            {"datasetRunItems": [{"traceId": None}]},
            {"datasetRunItems": [{"traceId": "trace-1"}]},
        ]

        def fake_api(method, path, *, body=None, query=None, auth=True):
            if method == "POST" and path == "/api/public/v2/datasets":
                return {"id": "dataset-1"}
            if method == "POST" and path == "/api/public/dataset-items":
                return {"id": "item-1"}
            if method == "POST" and path == "/api/public/dataset-run-items":
                return {"id": "run-item-1"}
            raise AssertionError(f"unexpected api call: {method} {path}")

        def fake_api_or_none_on_404(method, path, *, body=None, query=None, auth=True):
            if method == "GET" and "/runs/" in path:
                return run_responses.pop(0)
            raise AssertionError(f"unexpected api_or_none_on_404 call: {method} {path}")

        tester.api = fake_api
        tester.api_or_none_on_404 = fake_api_or_none_on_404

        message = tester.check_datasets()

        self.assertIn("dataset=", message)
        self.assertEqual(run_responses, [])


if __name__ == "__main__":
    unittest.main()
