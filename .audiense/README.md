# Custom Trino images

We run connector patches in production before they are merged upstream. This
directory builds an image for that: an **official Trino release** with the
connectors we have touched rebuilt from that same release tag, with our pending
pull requests applied on top.

Nothing here changes the Trino engine. Only connector plugin directories are
replaced, which is why the official image can be used as-is underneath.

## How it works

```
  trinodb/trino:483  ─────────────────────────────┐
                                                  │
  tag 483 ──► cherry-pick pending PRs ──► mvn package ──► plugins/  ──► image
```

1. A throwaway git worktree is created at the release tag.
2. Every PR listed in `custom-image.json` is cherry-picked onto it.
3. The touched connectors are tested and packaged.
4. The resulting plugin directories are copied over the official image.

The two properties that matter:

- **The plugin is built from the same source as the server it runs on.** Building
  a connector from `master` and dropping it into an older release puts a
  `trino-plugin-toolkit` compiled against a different SPI inside the plugin
  classpath. It usually works, until it does not.
- **Only the connectors are compiled.** At a release tag every module version is
  exact (`483`, not `483-SNAPSHOT`), so every Trino dependency resolves from Maven
  Central. Compiling `trino-opensearch` takes seconds instead of rebuilding the
  engine. The handful of modules Trino does not publish to Central are listed
  under `extraModules`.

## Running it

From CI, use the **custom image** workflow (`workflow_dispatch`). It builds and
pushes to ECR.

Locally:

```bash
.audiense/build.sh             # release from custom-image.json, with tests
.audiense/build.sh -t 482 -x   # another release, skipping tests
```

That leaves a ready build context in `target-custom-image/context`:

```bash
docker buildx build target-custom-image/context \
    --platform linux/amd64,linux/arm64 \
    --build-arg BASE_TAG=483 \
    --tag <repo>:483-CUSTOM --push
```

The build context never touches your checkout: everything happens in a worktree
under `target-custom-image/src`.

## Keeping `custom-image.json` current

```json
{
    "pr": 29209,
    "title": "Add support for match_only_text field type in OpenSearch",
    "ref": "origin/pedroluislopez/opensearch-match-only-text"
}
```

- **A PR is merged upstream** → delete its entry. Once it ships in a release, the
  official image already has it.
- **A PR gets new commits** → nothing to do. Only the ref is recorded, so the
  build always takes whatever the branch currently holds.
- **A new connector is touched** → add the module to `plugins`.

The commits taken from a branch are the ones it carries over upstream `master`,
so the branches must stay rebased on upstream, which is what we need for the pull
requests anyway.

### When a patch does not apply to the release

Our branches target `master`, and a release tag can be hundreds of commits
behind it, so sooner or later a cherry-pick conflicts. The build stops and prints
the conflicting files.

Resolve it once against that release, push the result, and record it:

```json
{
    "pr": 31177,
    "ref": "origin/pedroluislopez/iceberg-domain-compaction-threshold",
    "ports": { "483": "origin/pedroluislopez/iceberg-domain-compaction-threshold-483" }
}
```

Every later build of `483` reuses the port; builds of other releases go back to
the branch. Ports for releases we no longer build can be deleted.

This is the one step that stays manual, and deliberately so: resolving a conflict
is a judgement about semantics, not a merge.

### Tests

`testArgs` narrows what runs per module. The Iceberg suite is far too large to
run in full on every image build, so it is restricted there. Cloud profiles are
never activated, so nothing needs external credentials.

## Setting up the AWS side

The workflow runs on a GitHub Actions runner hosted by AWS CodeBuild, so AWS
calls use the project's service role rather than credentials stored in GitHub.

The runner is `large_github_runner` in the terraform repository, which builds the
CodeBuild project `production-large-github-runner-erc-novpc`. The repository
variable **`CODEBUILD_PROJECT_NAME`** carries that name, and the workflow turns it
into the runner label.

LARGE (16 GB) rather than the shared MEDIUM runner because the connector suites
start OpenSearch under testcontainers next to an in-process Trino query runner,
which peaks around 8 GB. That project also raises the build timeout, since the
module defaults to 15 minutes.

Because the Dockerfile only copies files, `linux/arm64` images build on an x86
project without qemu, so one project serves both platforms.

## What this does not cover

Changes outside a connector — the engine, the SPI, the client — cannot be shipped
by replacing a plugin directory. Those need a full server build; Trino's own
`core/docker/build.sh` does that from a release tarball.
