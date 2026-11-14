const base = require('@camunda8/sdk-infra/configs/release.config.base.cjs');

// D packages are consumed from git tags (and, once registered, code.dlang.org).
// There is no compiled artifact to upload: publishing is "stamp
// runtime/source/camunda/version_.d, push the tag". dub.json carries no
// "version" (the registry derives it from the tag and rejects one). scripts/notify-dub.sh then pings
// the DUB registry so the new version syncs immediately.
module.exports = {
  ...base,
  plugins: [
    ...base.plugins,
    [
      '@semantic-release/exec',
      {
        prepareCmd: 'bash scripts/prepare-release.sh "${nextRelease.version}"',
        // notify-dub syncs code.dlang.org; mark-latest makes a stable/N release
        // GitHub "Latest" (semantic-release never does for maintenance branches).
        successCmd:
          'bash scripts/notify-dub.sh "${nextRelease.version}" && bash scripts/mark-latest.sh "${nextRelease.version}"',
      },
    ],
    [
      '@semantic-release/git',
      {
        assets: ['CHANGELOG.md', 'runtime/source/camunda/version_.d'],
        message:
          'chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}',
      },
    ],
    [
      '@semantic-release/github',
      {
        successComment: false,
      },
    ],
  ],
};
