/+ dub.sdl:
name "generate-config-reference"
targetPath ".dub/bin"
+/
/**
Generate / check the configuration reference table in README.md.

The table is the single source of truth for supported CAMUNDA_* variables
(kept here next to the resolver in runtime/source/camunda/config.d). Injected between
<!-- BEGIN_CONFIG_REFERENCE --> and <!-- END_CONFIG_REFERENCE -->.

Usage:
    dub run -q --single scripts/generate-config-reference.d
    dub run -q --single scripts/generate-config-reference.d -- --check
*/
module generate_config_reference;

import std.algorithm : canFind;
import std.array : join;
import std.file : readText, write;
import std.path : buildPath, dirName;
import std.stdio : stderr, writeln;
import std.string : indexOf;

enum BEGIN = "<!-- BEGIN_CONFIG_REFERENCE -->";
enum END = "<!-- END_CONFIG_REFERENCE -->";

struct Var
{
    string name, defaultValue, description;
}

// Mirrors CamundaConfig.resolve / the JS SCHEMA. Keep in lockstep with
// runtime/source/camunda/config.d — the --check gate fails the README if this table
// is not what is published.
immutable Var[] CONFIG_REFERENCE = [
    Var("CAMUNDA_REST_ADDRESS", "http://localhost:8080",
        "Cluster REST endpoint. `/v2` is appended automatically when absent."),
    Var("ZEEBE_REST_ADDRESS", "",
        "Legacy alias for `CAMUNDA_REST_ADDRESS` (used only when the latter is unset)."),
    Var("CAMUNDA_REST_ADDRESS_EXACT", "false",
        "Disable the automatic `/v2` suffix so `CAMUNDA_REST_ADDRESS` is used as the base path."),
    Var("CAMUNDA_AUTH_STRATEGY", "",
        "`NONE`, `BASIC`, or `OAUTH`. Auto-detected from the supplied credentials when unset."),
    Var("CAMUNDA_CLIENT_ID", "", "OAuth client id."),
    Var("CAMUNDA_CLIENT_SECRET", "", "OAuth client secret."),
    Var("CAMUNDA_CLIENT_AUTH_CLIENTID", "", "Legacy alias for `CAMUNDA_CLIENT_ID`."),
    Var("CAMUNDA_CLIENT_AUTH_CLIENTSECRET", "", "Legacy alias for `CAMUNDA_CLIENT_SECRET`."),
    Var("CAMUNDA_OAUTH_URL", "https://login.cloud.camunda.io/oauth/token",
        "OAuth token endpoint."),
    Var("CAMUNDA_TOKEN_AUDIENCE", "zeebe.camunda.io", "OAuth token audience."),
    Var("CAMUNDA_OAUTH_SCOPE", "", "Optional OAuth scope."),
    Var("CAMUNDA_OAUTH_CACHE_DIR", "",
        "Directory for the on-disk OAuth token cache. Unset disables disk caching."),
    Var("CAMUNDA_BASIC_AUTH_USERNAME", "", "Basic-auth username."),
    Var("CAMUNDA_BASIC_AUTH_PASSWORD", "", "Basic-auth password."),
    Var("CAMUNDA_DEFAULT_TENANT_ID", "",
        "Default tenant id applied to tenant-aware operations (alias `CAMUNDA_TENANT_ID`)."),
    Var("CAMUNDA_TENANT_ID", "", "Alias for `CAMUNDA_DEFAULT_TENANT_ID`."),
    Var("CAMUNDA_TENANT_IDS", "",
        "Comma-separated default tenant ids (e.g. for job activation)."),
    Var("CAMUNDA_SDK_BACKPRESSURE_PROFILE", "BALANCED",
        "`BALANCED`, `CONSERVATIVE`, `AGGRESSIVE`, or `LEGACY` (observe-only)."),
    Var("CAMUNDA_SDK_HTTP_RETRY_MAX_ATTEMPTS", "3",
        "Total HTTP attempts for transient failures (429, 502, 503, 504, network)."),
    Var("CAMUNDA_SDK_HTTP_RETRY_BASE_DELAY_MS", "100", "Base backoff delay, in milliseconds."),
    Var("CAMUNDA_SDK_HTTP_RETRY_MAX_DELAY_MS", "2000", "Backoff cap, in milliseconds."),
    Var("CAMUNDA_SDK_EVENTUAL_POLL_DEFAULT_MS", "10000",
        "Default overall timeout for `eventual` polling, in milliseconds."),
    Var("CAMUNDA_SDK_LOG_LEVEL", "info",
        "`off`, `error`, `warn`, `info`, `debug`, or `trace`."),
    Var("CAMUNDA_WORKER_TIMEOUT", "60000", "Default job activation timeout, in milliseconds."),
    Var("CAMUNDA_WORKER_MAX_CONCURRENT_JOBS", "32",
        "Default maximum number of jobs a worker activates at once."),
    Var("CAMUNDA_WORKER_REQUEST_TIMEOUT", "10000",
        "Default long-poll request timeout, in milliseconds."),
    Var("CAMUNDA_WORKER_NAME", "d-sdk-worker", "Default worker name reported when activating jobs."),
    Var("CAMUNDA_WORKER_STARTUP_JITTER_MAX_SECONDS", "0",
        "Maximum random startup delay before the first poll, in seconds."),
    Var("CAMUNDA_MTLS_CERT", "", "Inline PEM client certificate."),
    Var("CAMUNDA_MTLS_KEY", "", "Inline PEM client private key."),
    Var("CAMUNDA_MTLS_CA", "", "Inline PEM CA bundle."),
    Var("CAMUNDA_MTLS_CERT_PATH", "", "Path to the client certificate for mutual TLS."),
    Var("CAMUNDA_MTLS_KEY_PATH", "", "Path to the client private key for mutual TLS."),
    Var("CAMUNDA_MTLS_CA_PATH", "", "Path to the CA bundle used to verify the server certificate."),
    Var("CAMUNDA_MTLS_KEY_PASSPHRASE", "", "Passphrase protecting the mTLS client key, if any."),
];

string buildTable()
{
    string[] lines = ["| Variable | Default | Description |", "| --- | --- | --- |"];
    foreach (v; CONFIG_REFERENCE)
    {
        const shown = v.defaultValue == "" ? "—" : "`" ~ v.defaultValue ~ "`";
        lines ~= "| `" ~ v.name ~ "` | " ~ shown ~ " | " ~ v.description ~ " |";
    }
    return lines.join("\n");
}

/// The README with the table injected, or null when the markers are missing.
string inject(string readme, string table)
{
    const begin = readme.indexOf(BEGIN);
    const end = readme.indexOf(END);
    if (begin < 0 || end < 0 || end < begin)
        return null;
    return readme[0 .. begin + BEGIN.length] ~ "\n\n" ~ table ~ "\n\n" ~ readme[end .. $];
}

int main(string[] argv)
{
    const check = argv[1 .. $].canFind("--check");
    const path = buildPath(dirName(dirName(__FILE_FULL_PATH__)), "README.md");
    const readme = readText(path);
    const updated = inject(readme, buildTable());
    if (updated is null)
    {
        stderr.writeln("ERROR: Could not find config-reference markers in README.md.\n"
            ~ "Add " ~ BEGIN ~ " and " ~ END ~ " where the table should appear.");
        return 1;
    }
    if (check)
    {
        if (readme != updated)
        {
            stderr.writeln("ERROR: Configuration reference in README.md is out of date.");
            stderr.writeln("Run: make config-reference");
            return 1;
        }
        writeln("OK: Configuration reference is up to date.");
        return 0;
    }
    if (readme == updated)
    {
        writeln("Configuration reference already up to date.");
        return 0;
    }
    write(path, updated);
    writeln("Updated configuration reference in README.md.");
    return 0;
}
