/// Package version, stamped by `scripts/prepare-release.sh` during semantic-release.
module camunda.version_;

@safe:

/// SemVer of this SDK (git tag `v` + this string).
enum sdkVersion = "10.4.0";

/// `User-Agent` product token.
enum sdkUserAgent = "camunda-orchestration-sdk-d/" ~ sdkVersion;
