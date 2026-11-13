const base = require('@camunda8/sdk-infra/configs/release.config.base.cjs');

// D packages are consumed from git tags (and, once registered, code.dlang.org).
// There is no compiled artifact to upload: publishing is "stamp dub.json +
// runtime/source/camunda/version_.d, push the tag". scripts/notify-dub.sh then pings
// the DUB registry so the new version syncs immediately.
module.exports = {
  ...base,
  plugins: [
    ...base.plugins,
    [
      '@semantic-release/exec',
      {
        prepareCmd: 'bash scripts/prepare-release.sh "${nextRelease.version}"',
        successCmd: 'bash scripts/notify-dub.sh "${nextRelease.version}"',
      },
    ],
    [
      '@semantic-release/git',
      {
        assets: ['CHANGELOG.md', 'dub.json', 'runtime/source/camunda/version_.d'],
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
