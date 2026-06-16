## Langfuse Feature Smoke Test

This folder contains a lightweight end-to-end smoke test for a running Langfuse
deployment. It exercises authentication, trace ingestion, sessions, scores,
datasets, prompts, comments, observations, and media upload URL creation through
public APIs and the Python SDK.

Run it with `uv` so the Python SDK does not need to be installed globally:

```bash
LANGFUSE_BASE_URL="http://localhost:3000" \
LANGFUSE_PUBLIC_KEY="pk-lf-..." \
LANGFUSE_SECRET_KEY="sk-lf-..." \
uv run --with langfuse scripts/smoke-tests/langfuse_feature_smoke_test.py
```

Optional environment variables:

- `LANGFUSE_TEST_PREFIX`: Prefix for temporary smoke-test records.
- `LANGFUSE_CLEANUP=true`: Best-effort cleanup for resources with public delete endpoints.
- `LANGFUSE_POLL_TIMEOUT_SECONDS`: Poll timeout for eventually consistent reads.
- `LANGFUSE_POLL_INTERVAL_SECONDS`: Poll interval for eventually consistent reads.

Run helper unit tests with:

```bash
python3 scripts/smoke-tests/tests/test_langfuse_feature_smoke_test.py
```
