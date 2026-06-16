#!/usr/bin/env python3
"""End-to-end Langfuse project smoke test.

Run with uv so the Langfuse SDK does not need to be installed globally:

    uv run --with langfuse scripts/langfuse_feature_smoke_test.py

Required environment variables:
    LANGFUSE_PUBLIC_KEY
    LANGFUSE_SECRET_KEY

Optional environment variables:
    LANGFUSE_BASE_URL=https://cloud.langfuse.com
    LANGFUSE_TEST_PREFIX=smoke
    LANGFUSE_CLEANUP=false
    LANGFUSE_POLL_TIMEOUT_SECONDS=60
    LANGFUSE_POLL_INTERVAL_SECONDS=2

The script creates uniquely named temporary records and verifies them via the
public API. It does not call any LLM provider; generation data is synthetic.
"""

from __future__ import annotations

import argparse
import base64
import dataclasses
import hashlib
import json
import os
import sys
import time
import traceback
import uuid
from datetime import datetime, timezone
from typing import Any, Callable, Iterable
from urllib import error, parse, request


DEFAULT_BASE_URL = "https://cloud.langfuse.com"


@dataclasses.dataclass(frozen=True)
class Config:
    public_key: str
    secret_key: str
    base_url: str
    prefix: str
    cleanup: bool
    poll_timeout_seconds: float
    poll_interval_seconds: float
    verbose: bool


@dataclasses.dataclass(frozen=True)
class CheckResult:
    name: str
    ok: bool
    message: str
    optional: bool = False


class ApiError(RuntimeError):
    def __init__(self, method: str, url: str, status: int, body: str):
        self.method = method
        self.url = url
        self.status = status
        self.body = body
        super().__init__(f"{method} {url} failed with HTTP {status}: {body[:500]}")


def normalize_base_url(value: str) -> str:
    parsed = parse.urlsplit(value.strip())
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("LANGFUSE_BASE_URL must be an http or https URL")
    if parsed.username or parsed.password:
        raise ValueError("LANGFUSE_BASE_URL must not include credentials")
    if parsed.query or parsed.fragment:
        raise ValueError("LANGFUSE_BASE_URL must not include query parameters or fragments")

    normalized = parse.urlunsplit(
        (parsed.scheme, parsed.netloc, parsed.path.rstrip("/"), "", ""),
    )
    return normalized or DEFAULT_BASE_URL


def build_api_url(
    base_url: str,
    path: str,
    query: dict[str, Any] | None = None,
) -> str:
    base = normalize_base_url(base_url)
    normalized_path = "/" + path.lstrip("/")
    url = f"{base}{normalized_path}"
    if query:
        clean_query = {k: v for k, v in query.items() if v is not None}
        if clean_query:
            url = f"{url}?{parse.urlencode(clean_query, doseq=True)}"
    return url


def redact(value: str) -> str:
    if len(value) < 12:
        return "***"
    return f"{value[:4]}...{value[-4:]}"


def parse_bool(value: str | None, default: bool = False) -> bool:
    if value is None or value == "":
        return default
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def wait_until(
    fn: Callable[[], Any | None],
    *,
    timeout_seconds: float,
    interval_seconds: float,
) -> Any | None:
    deadline = time.monotonic() + timeout_seconds
    while True:
        value = fn()
        if value:
            return value
        if time.monotonic() >= deadline:
            return None
        time.sleep(interval_seconds)


def exit_code_for_results(results: Iterable[CheckResult]) -> int:
    return 1 if any(not result.ok and not result.optional for result in results) else 0


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def sha256_base64(content: bytes) -> str:
    return base64.b64encode(hashlib.sha256(content).digest()).decode("ascii")


class LangfuseSmokeTester:
    def __init__(self, config: Config):
        self.config = config
        self.run_id = f"{config.prefix}-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"
        self.project_id: str | None = None
        self.trace_id: str | None = None
        self.observation_ids: list[str] = []
        self.score_id: str | None = None
        self.dataset_name = f"{self.run_id}-dataset"
        self.dataset_id: str | None = None
        self.dataset_item_id: str | None = None
        self.dataset_run_name = f"{self.run_id}-run"
        self.prompt_name = f"{self.run_id}-prompt"
        self.comment_id: str | None = None
        self.session_id = f"{self.run_id}-session"
        self.user_id = f"{self.run_id}-user"
        self.trace_name = f"{self.run_id}-trace"
        self.tag = self.run_id

    def run(self) -> list[CheckResult]:
        print("Langfuse feature smoke test")
        print(f"Base URL: {self.config.base_url}")
        print(f"Public key: {redact(self.config.public_key)}")
        print(f"Run ID: {self.run_id}")
        print("")

        checks: list[tuple[str, Callable[[], str], bool]] = [
            ("health endpoints", self.check_health, False),
            ("auth and project access", self.check_project_access, False),
            ("trace/span/generation ingestion", self.check_tracing, False),
            ("trace user and session", self.check_session, False),
            ("scores and feedback", self.check_scores, False),
            ("datasets and dataset runs", self.check_datasets, False),
            ("prompt management", self.check_prompts, False),
            ("comments", self.check_comments, False),
            ("observations API", self.check_observations_api, False),
            ("media upload URL", self.check_media_upload_url, True),
        ]

        results: list[CheckResult] = []
        for name, fn, optional in checks:
            result = self._run_check(name, fn, optional=optional)
            results.append(result)

        if self.config.cleanup:
            results.append(self._run_check("cleanup", self.cleanup, optional=True))

        print_summary(results)
        return results

    def _run_check(
        self,
        name: str,
        fn: Callable[[], str],
        *,
        optional: bool = False,
    ) -> CheckResult:
        label = f"{name} (optional)" if optional else name
        print(f"-> {label}")
        try:
            message = fn()
        except Exception as exc:  # noqa: BLE001 - CLI should report all failures.
            if self.config.verbose:
                traceback.print_exc()
            message = str(exc)
            print(f"   FAIL: {message}")
            return CheckResult(name=name, ok=False, message=message, optional=optional)

        print(f"   OK: {message}")
        return CheckResult(name=name, ok=True, message=message, optional=optional)

    def api(
        self,
        method: str,
        path: str,
        *,
        body: dict[str, Any] | None = None,
        query: dict[str, Any] | None = None,
        auth: bool = True,
    ) -> Any:
        url = build_api_url(self.config.base_url, path, query)
        headers = {"Accept": "application/json"}
        data: bytes | None = None
        if body is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(body).encode("utf-8")
        if auth:
            credentials = f"{self.config.public_key}:{self.config.secret_key}".encode(
                "utf-8",
            )
            headers["Authorization"] = (
                "Basic " + base64.b64encode(credentials).decode("ascii")
            )

        req = request.Request(url, data=data, headers=headers, method=method.upper())
        try:
            with request.urlopen(req, timeout=30) as response:  # noqa: S310 - URL is user-supplied CLI config.
                raw = response.read().decode("utf-8")
                if not raw:
                    return None
                return json.loads(raw)
        except error.HTTPError as exc:
            raw_body = exc.read().decode("utf-8", errors="replace")
            raise ApiError(method.upper(), url, exc.code, raw_body) from exc

    def api_or_none_on_404(self, method: str, path: str, **kwargs: Any) -> Any | None:
        try:
            return self.api(method, path, **kwargs)
        except ApiError as exc:
            if exc.status == 404:
                return None
            raise

    def check_health(self) -> str:
        health = self.api("GET", "/api/public/health", auth=False)
        ready = self.api("GET", "/api/public/ready", auth=False)
        return f"health={short_json(health)}, ready={short_json(ready)}"

    def check_project_access(self) -> str:
        response = self.api("GET", "/api/public/projects")
        projects = response.get("data") if isinstance(response, dict) else None
        if not projects:
            raise RuntimeError("project API key authenticated, but no project was returned")
        project = projects[0]
        self.project_id = project["id"]
        return f"project={project.get('name', self.project_id)} ({self.project_id})"

    def check_tracing(self) -> str:
        try:
            from langfuse import Langfuse, propagate_attributes
        except ModuleNotFoundError as exc:
            raise RuntimeError(
                "Missing Python package 'langfuse'. Run with: "
                "uv run --with langfuse scripts/langfuse_feature_smoke_test.py",
            ) from exc

        langfuse = Langfuse(
            public_key=self.config.public_key,
            secret_key=self.config.secret_key,
            base_url=self.config.base_url,
        )

        with propagate_attributes(
            user_id=self.user_id,
            session_id=self.session_id,
            metadata={"smoke_run_id": self.run_id},
            version="smoke-test",
            tags=["langfuse-smoke-test", self.tag],
            trace_name=self.trace_name,
        ):
            with langfuse.start_as_current_observation(
                name="smoke-root-span",
                as_type="span",
                input={"question": "Does Langfuse record this smoke-test trace?"},
                metadata={"feature": "tracing"},
            ) as span:
                with span.start_as_current_observation(
                    name="smoke-synthetic-generation",
                    as_type="generation",
                    model="smoke-test-model",
                    input=[{"role": "user", "content": "ping"}],
                    model_parameters={"temperature": 0, "max_tokens": 8},
                ) as generation:
                    generation.update(
                        output={"role": "assistant", "content": "pong"},
                        usage_details={"prompt_tokens": 3, "completion_tokens": 2},
                        cost_details={"total_cost": 0.0},
                    )

                langfuse.set_current_trace_io(
                    input={"smoke_test": self.run_id},
                    output={"status": "recorded"},
                )
                if hasattr(span, "score_trace"):
                    span.score_trace(
                        name=f"{self.run_id}-sdk-feedback",
                        value=1,
                        data_type="NUMERIC",
                        comment="SDK-created smoke-test feedback score",
                    )
                span.update(output={"root_span": "complete"})

        langfuse.flush()

        trace = wait_until(
            self.find_created_trace,
            timeout_seconds=self.config.poll_timeout_seconds,
            interval_seconds=self.config.poll_interval_seconds,
        )
        if not trace:
            raise RuntimeError(
                f"trace '{self.trace_name}' was not visible after "
                f"{self.config.poll_timeout_seconds:g}s",
            )

        self.trace_id = trace["id"]
        detailed = self.get_trace(self.trace_id)
        observations = detailed.get("observations") or []
        self.observation_ids = [obs["id"] for obs in observations if obs.get("id")]
        observation_names = {obs.get("name") for obs in observations}
        if "smoke-root-span" not in observation_names:
            raise RuntimeError("root span was not returned in trace observations")
        if "smoke-synthetic-generation" not in observation_names:
            raise RuntimeError("synthetic generation was not returned in trace observations")
        return f"trace={self.trace_id}, observations={len(observations)}"

    def find_created_trace(self) -> dict[str, Any] | None:
        response = self.api(
            "GET",
            "/api/public/traces",
            query={
                "name": self.trace_name,
                "limit": 10,
                "fields": "core,io,scores,observations,metrics",
            },
        )
        for trace in response.get("data", []):
            if trace.get("name") == self.trace_name:
                return trace
        return None

    def get_trace(self, trace_id: str) -> dict[str, Any]:
        return self.api(
            "GET",
            f"/api/public/traces/{parse.quote(trace_id, safe='')}",
            query={"fields": "core,io,scores,observations,metrics"},
        )

    def check_session(self) -> str:
        trace = self.require_trace()
        if trace.get("userId") != self.user_id:
            raise RuntimeError(
                f"trace userId mismatch: expected {self.user_id}, got {trace.get('userId')}",
            )
        if trace.get("sessionId") != self.session_id:
            raise RuntimeError(
                f"trace sessionId mismatch: expected {self.session_id}, got {trace.get('sessionId')}",
            )

        session = wait_until(
            lambda: self.api_or_none_on_404(
                "GET",
                f"/api/public/sessions/{parse.quote(self.session_id, safe='')}",
            ),
            timeout_seconds=self.config.poll_timeout_seconds,
            interval_seconds=self.config.poll_interval_seconds,
        )
        traces = session.get("traces", []) if isinstance(session, dict) else []
        if not any(item.get("id") == self.trace_id for item in traces):
            raise RuntimeError("session endpoint did not return the created trace")
        return f"userId={self.user_id}, sessionId={self.session_id}"

    def check_scores(self) -> str:
        if not self.trace_id:
            raise RuntimeError("trace must be created before creating scores")
        self.score_id = f"{self.run_id}-api-score"
        score_name = f"{self.run_id}-feedback"
        self.api(
            "POST",
            "/api/public/scores",
            body={
                "id": self.score_id,
                "traceId": self.trace_id,
                "name": score_name,
                "value": 1,
                "dataType": "NUMERIC",
                "comment": "API-created smoke-test user feedback",
                "metadata": {"smoke_run_id": self.run_id},
            },
        )

        score = wait_until(
            lambda: self.find_score(self.score_id),
            timeout_seconds=self.config.poll_timeout_seconds,
            interval_seconds=self.config.poll_interval_seconds,
        )
        if not score:
            raise RuntimeError(f"score '{self.score_id}' was not visible via scores API")
        return f"score={self.score_id}, name={score.get('name')}"

    def find_score(self, score_id: str) -> dict[str, Any] | None:
        response = self.api(
            "GET",
            "/api/public/scores",
            query={"scoreIds": score_id, "limit": 10},
        )
        for score in response.get("data", []):
            if score.get("id") == score_id:
                return score
        return None

    def check_datasets(self) -> str:
        if not self.trace_id:
            raise RuntimeError("trace must be created before linking dataset run items")

        dataset = self.api(
            "POST",
            "/api/public/v2/datasets",
            body={
                "name": self.dataset_name,
                "description": "Langfuse smoke-test dataset",
                "metadata": {"smoke_run_id": self.run_id},
            },
        )
        self.dataset_id = dataset["id"]

        item = self.api(
            "POST",
            "/api/public/dataset-items",
            body={
                "datasetName": self.dataset_name,
                "input": {"question": "ping"},
                "expectedOutput": {"answer": "pong"},
                "metadata": {"smoke_run_id": self.run_id},
            },
        )
        self.dataset_item_id = item["id"]

        self.api(
            "POST",
            "/api/public/dataset-run-items",
            body={
                "runName": self.dataset_run_name,
                "runDescription": "Langfuse smoke-test dataset run",
                "metadata": {"smoke_run_id": self.run_id},
                "datasetItemId": self.dataset_item_id,
                "traceId": self.trace_id,
                "createdAt": utc_now_iso(),
            },
        )

        def find_run_with_trace() -> dict[str, Any] | None:
            run = self.api_or_none_on_404(
                "GET",
                f"/api/public/datasets/{parse.quote(self.dataset_name, safe='')}/runs/{parse.quote(self.dataset_run_name, safe='')}",
            )
            run_items = run.get("datasetRunItems", []) if isinstance(run, dict) else []
            if any(item.get("traceId") == self.trace_id for item in run_items):
                return run
            return None

        run = wait_until(
            find_run_with_trace,
            timeout_seconds=self.config.poll_timeout_seconds,
            interval_seconds=self.config.poll_interval_seconds,
        )
        run_items = run.get("datasetRunItems", []) if isinstance(run, dict) else []
        if not any(item.get("traceId") == self.trace_id for item in run_items):
            raise RuntimeError("dataset run did not include the created trace")
        return f"dataset={self.dataset_name}, item={self.dataset_item_id}, run={self.dataset_run_name}"

    def check_prompts(self) -> str:
        prompt_text = "Respond with pong for smoke-test ping."
        self.api(
            "POST",
            "/api/public/prompts",
            body={
                "name": self.prompt_name,
                "type": "text",
                "prompt": prompt_text,
                "labels": [],
                "isActive": True,
                "config": {"temperature": 0},
                "tags": ["langfuse-smoke-test", self.tag],
            },
        )
        prompt = self.api(
            "GET",
            "/api/public/prompts",
            query={"name": self.prompt_name},
        )
        if prompt.get("name") != self.prompt_name or prompt.get("prompt") != prompt_text:
            raise RuntimeError("created prompt did not round-trip through GET /prompts")
        return f"prompt={self.prompt_name}, version={prompt.get('version')}"

    def check_comments(self) -> str:
        if not self.project_id or not self.trace_id:
            raise RuntimeError("project and trace must exist before creating comments")
        content = f"Langfuse smoke-test comment for {self.run_id}"
        response = self.api(
            "POST",
            "/api/public/comments",
            body={
                "projectId": self.project_id,
                "content": content,
                "objectId": self.trace_id,
                "objectType": "TRACE",
                "authorUserId": self.user_id,
            },
        )
        self.comment_id = response["id"]

        comment = self.api(
            "GET",
            f"/api/public/comments/{parse.quote(self.comment_id, safe='')}",
        )
        if comment.get("content") != content or comment.get("objectId") != self.trace_id:
            raise RuntimeError("created comment did not round-trip through GET /comments/{id}")
        return f"comment={self.comment_id}"

    def check_observations_api(self) -> str:
        if not self.observation_ids:
            raise RuntimeError("no observation IDs were captured from the trace")

        observation_id = self.observation_ids[0]
        observation = self.api(
            "GET",
            f"/api/public/observations/{parse.quote(observation_id, safe='')}",
        )
        if observation.get("traceId") != self.trace_id:
            raise RuntimeError("observation endpoint returned an unexpected traceId")
        observations = self.api(
            "GET",
            "/api/public/observations",
            query={"traceId": self.trace_id, "limit": 20},
        )
        count = len(observations.get("data", []))
        if count < 1:
            raise RuntimeError("observation list endpoint returned no observations")
        return f"observation={observation_id}, listed={count}"

    def check_media_upload_url(self) -> str:
        if not self.trace_id:
            raise RuntimeError("trace must exist before requesting media upload URL")
        content = b"langfuse smoke test media"
        response = self.api(
            "POST",
            "/api/public/media",
            body={
                "traceId": self.trace_id,
                "contentType": "text/plain",
                "contentLength": len(content),
                "sha256Hash": sha256_base64(content),
                "field": "input",
            },
        )
        media_id = response.get("mediaId")
        if not media_id:
            raise RuntimeError("media endpoint did not return a mediaId")
        return f"mediaId={media_id}, uploadUrl={'yes' if response.get('uploadUrl') else 'no'}"

    def cleanup(self) -> str:
        deleted: list[str] = []
        failures: list[str] = []

        cleanup_calls: list[tuple[str, str, str]] = []
        if self.score_id:
            cleanup_calls.append(("DELETE", f"/api/public/scores/{self.score_id}", "score"))
        if self.dataset_name and self.dataset_run_name:
            cleanup_calls.append(
                (
                    "DELETE",
                    f"/api/public/datasets/{parse.quote(self.dataset_name, safe='')}/runs/{parse.quote(self.dataset_run_name, safe='')}",
                    "dataset run",
                ),
            )
        if self.dataset_item_id:
            cleanup_calls.append(
                ("DELETE", f"/api/public/dataset-items/{self.dataset_item_id}", "dataset item"),
            )
        if self.trace_id:
            cleanup_calls.append(("DELETE", f"/api/public/traces/{self.trace_id}", "trace"))

        for method, path, label in cleanup_calls:
            try:
                self.api(method, path)
                deleted.append(label)
            except Exception as exc:  # noqa: BLE001 - cleanup should be best effort.
                failures.append(f"{label}: {exc}")

        if failures:
            return f"deleted={deleted}; cleanup failures={failures}"
        if not deleted:
            return "nothing to delete"
        return "deleted " + ", ".join(deleted)

    def require_trace(self) -> dict[str, Any]:
        if not self.trace_id:
            raise RuntimeError("trace has not been created yet")
        return self.get_trace(self.trace_id)


def short_json(value: Any) -> str:
    text = json.dumps(value, sort_keys=True) if value is not None else "null"
    return text if len(text) <= 120 else text[:117] + "..."


def print_summary(results: list[CheckResult]) -> None:
    print("\nSummary")
    print("=======")
    for result in results:
        status = "PASS" if result.ok else "SKIP" if result.optional else "FAIL"
        optional = " optional" if result.optional else ""
        print(f"{status:4} {result.name}{optional}: {result.message}")


def config_from_env_and_args(argv: list[str]) -> Config:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=os.getenv("LANGFUSE_BASE_URL", DEFAULT_BASE_URL))
    parser.add_argument("--public-key", default=os.getenv("LANGFUSE_PUBLIC_KEY"))
    parser.add_argument("--secret-key", default=os.getenv("LANGFUSE_SECRET_KEY"))
    parser.add_argument("--prefix", default=os.getenv("LANGFUSE_TEST_PREFIX", "smoke"))
    parser.add_argument(
        "--cleanup",
        action="store_true",
        default=parse_bool(os.getenv("LANGFUSE_CLEANUP"), False),
        help="Best-effort cleanup for resources with public delete endpoints.",
    )
    parser.add_argument(
        "--poll-timeout-seconds",
        type=float,
        default=float(os.getenv("LANGFUSE_POLL_TIMEOUT_SECONDS", "60")),
    )
    parser.add_argument(
        "--poll-interval-seconds",
        type=float,
        default=float(os.getenv("LANGFUSE_POLL_INTERVAL_SECONDS", "2")),
    )
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)

    if not args.public_key:
        parser.error("LANGFUSE_PUBLIC_KEY or --public-key is required")
    if not args.secret_key:
        parser.error("LANGFUSE_SECRET_KEY or --secret-key is required")
    if args.poll_timeout_seconds < 0:
        parser.error("poll timeout must be >= 0")
    if args.poll_interval_seconds < 0:
        parser.error("poll interval must be >= 0")

    return Config(
        public_key=args.public_key,
        secret_key=args.secret_key,
        base_url=normalize_base_url(args.base_url),
        prefix=args.prefix,
        cleanup=args.cleanup,
        poll_timeout_seconds=args.poll_timeout_seconds,
        poll_interval_seconds=args.poll_interval_seconds,
        verbose=args.verbose,
    )


def main(argv: list[str] | None = None) -> int:
    config = config_from_env_and_args(sys.argv[1:] if argv is None else argv)
    tester = LangfuseSmokeTester(config)
    return exit_code_for_results(tester.run())


if __name__ == "__main__":
    raise SystemExit(main())
