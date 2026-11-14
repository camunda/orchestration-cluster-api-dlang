#!/usr/bin/env python3
"""Generate / check the configuration reference table in README.md.

The table is the single source of truth for supported CAMUNDA_* variables
(kept here next to the resolver in runtime/source/camunda/config.d). Injected between
<!-- BEGIN_CONFIG_REFERENCE --> and <!-- END_CONFIG_REFERENCE -->.

Usage:
    python3 scripts/generate-config-reference.py
    python3 scripts/generate-config-reference.py --check
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
README = ROOT / "README.md"
BEGIN = "<!-- BEGIN_CONFIG_REFERENCE -->"
END = "<!-- END_CONFIG_REFERENCE -->"

# Mirrors CamundaConfig.resolve / the JS SCHEMA. Keep in lockstep with
# runtime/source/camunda/config.d — the --check gate fails the README if this table
# is not what is published.
CONFIG_REFERENCE: list[tuple[str, str, str]] = [
    ("CAMUNDA_REST_ADDRESS", "http://localhost:8080",
     "Cluster REST endpoint. `/v2` is appended automatically when absent."),
    ("ZEEBE_REST_ADDRESS", "",
     "Legacy alias for `CAMUNDA_REST_ADDRESS` (used only when the latter is unset)."),
    ("CAMUNDA_REST_ADDRESS_EXACT", "false",
     "Disable the automatic `/v2` suffix so `CAMUNDA_REST_ADDRESS` is used as the base path."),
    ("CAMUNDA_AUTH_STRATEGY", "",
     "`NONE`, `BASIC`, or `OAUTH`. Auto-detected from the supplied credentials when unset."),
    ("CAMUNDA_CLIENT_ID", "", "OAuth client id."),
    ("CAMUNDA_CLIENT_SECRET", "", "OAuth client secret."),
    ("CAMUNDA_CLIENT_AUTH_CLIENTID", "", "Legacy alias for `CAMUNDA_CLIENT_ID`."),
    ("CAMUNDA_CLIENT_AUTH_CLIENTSECRET", "", "Legacy alias for `CAMUNDA_CLIENT_SECRET`."),
    ("CAMUNDA_OAUTH_URL", "https://login.cloud.camunda.io/oauth/token",
     "OAuth token endpoint."),
    ("CAMUNDA_TOKEN_AUDIENCE", "zeebe.camunda.io", "OAuth token audience."),
    ("CAMUNDA_OAUTH_SCOPE", "", "Optional OAuth scope."),
    ("CAMUNDA_OAUTH_CACHE_DIR", "",
     "Directory for the on-disk OAuth token cache. Unset disables disk caching."),
    ("CAMUNDA_BASIC_AUTH_USERNAME", "", "Basic-auth username."),
    ("CAMUNDA_BASIC_AUTH_PASSWORD", "", "Basic-auth password."),
    ("CAMUNDA_DEFAULT_TENANT_ID", "",
     "Default tenant id applied to tenant-aware operations (alias `CAMUNDA_TENANT_ID`)."),
    ("CAMUNDA_DEFAULT_HEADERS", "",
     "Custom headers sent with every API request, as a JSON object of header name to value "
     "(`{\"X-Api-Key\":\"…\"}`). Applied last, merged case-insensitively (may replace "
     "`Authorization`, but not `Content-Type`, which is fixed by the request body); never "
     "sent to the OAuth token endpoint. Values may be secrets."),
    ("CAMUNDA_TENANT_ID", "", "Alias for `CAMUNDA_DEFAULT_TENANT_ID`."),
    ("CAMUNDA_TENANT_IDS", "",
     "Comma-separated default tenant ids (e.g. for job activation)."),
    ("CAMUNDA_SDK_BACKPRESSURE_PROFILE", "BALANCED",
     "`BALANCED`, `CONSERVATIVE`, `AGGRESSIVE`, or `LEGACY` (observe-only)."),
    ("CAMUNDA_SDK_HTTP_RETRY_MAX_ATTEMPTS", "3",
     "Total HTTP attempts for transient failures (429, 502, 503, 504, network)."),
    ("CAMUNDA_SDK_HTTP_RETRY_BASE_DELAY_MS", "100", "Base backoff delay, in milliseconds."),
    ("CAMUNDA_SDK_HTTP_RETRY_MAX_DELAY_MS", "2000", "Backoff cap, in milliseconds."),
    ("CAMUNDA_SDK_EVENTUAL_POLL_DEFAULT_MS", "10000",
     "Default overall timeout for `eventual` polling, in milliseconds."),
    ("CAMUNDA_SDK_LOG_LEVEL", "info",
     "`off`, `error`, `warn`, `info`, `debug`, or `trace`."),
    ("CAMUNDA_WORKER_TIMEOUT", "60000", "Default job activation timeout, in milliseconds."),
    ("CAMUNDA_WORKER_MAX_CONCURRENT_JOBS", "32",
     "Default maximum number of jobs a worker activates at once."),
    ("CAMUNDA_WORKER_REQUEST_TIMEOUT", "10000",
     "Default long-poll request timeout, in milliseconds."),
    ("CAMUNDA_WORKER_NAME", "d-sdk-worker", "Default worker name reported when activating jobs."),
    ("CAMUNDA_WORKER_STARTUP_JITTER_MAX_SECONDS", "0",
     "Maximum random startup delay before the first poll, in seconds."),
    ("CAMUNDA_MTLS_CERT", "", "Inline PEM client certificate."),
    ("CAMUNDA_MTLS_KEY", "", "Inline PEM client private key."),
    ("CAMUNDA_MTLS_CA", "", "Inline PEM CA bundle."),
    ("CAMUNDA_MTLS_CERT_PATH", "", "Path to the client certificate for mutual TLS."),
    ("CAMUNDA_MTLS_KEY_PATH", "", "Path to the client private key for mutual TLS."),
    ("CAMUNDA_MTLS_CA_PATH", "", "Path to the CA bundle used to verify the server certificate."),
    ("CAMUNDA_MTLS_KEY_PASSPHRASE", "", "Passphrase protecting the mTLS client key, if any."),
]


def build_table() -> str:
    lines = ["| Variable | Default | Description |", "| --- | --- | --- |"]
    for variable, default, description in CONFIG_REFERENCE:
        shown = "—" if default == "" else f"`{default}`"
        lines.append(f"| `{variable}` | {shown} | {description} |")
    return "\n".join(lines)


def inject(readme: str, table: str) -> str:
    begin = readme.find(BEGIN)
    end = readme.find(END)
    if begin < 0 or end < 0 or end < begin:
        sys.exit(
            f"ERROR: Could not find config-reference markers in README.md.\n"
            f"Add {BEGIN} and {END} where the table should appear.\n"
        )
    before = readme[: begin + len(BEGIN)]
    after = readme[end:]
    return before + "\n\n" + table + "\n\n" + after


def main() -> int:
    check = "--check" in sys.argv
    readme = README.read_text(encoding="utf-8")
    updated = inject(readme, build_table())
    if check:
        if readme != updated:
            print("ERROR: Configuration reference in README.md is out of date.", file=sys.stderr)
            print("Run: make config-reference", file=sys.stderr)
            return 1
        print("OK: Configuration reference is up to date.")
        return 0
    if readme == updated:
        print("Configuration reference already up to date.")
        return 0
    README.write_text(updated, encoding="utf-8")
    print("Updated configuration reference in README.md.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
