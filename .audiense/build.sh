#!/usr/bin/env bash
#
# Assembles the build context for a custom Trino image: the official release
# image plus the connectors rebuilt from that same release tag with the patches
# that are still awaiting review upstream.
#
# Everything happens in a throwaway git worktree under target-custom-image/, so
# the checkout this runs from is never modified.
#
# See .audiense/README.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
CONFIG="${SCRIPT_DIR}/custom-image.json"
BUILD_DIR="${REPO_ROOT}/target-custom-image"
SRC_DIR="${BUILD_DIR}/src"
CONTEXT_DIR="${BUILD_DIR}/context"
WORK_BRANCH="custom-image-build"

BASE_TAG=
RUN_TESTS=true

usage() {
    cat <<EOF 1>&2
Usage: $0 [-h] [-t <TAG>] [-x]

Prepares target-custom-image/context, ready for "docker buildx build".

-h  Display help
-t  Trino release tag to build on, defaults to baseTag in custom-image.json
-x  Skip the connector test suites
EOF
}

while getopts ":ht:x" opt; do
    case "${opt}" in
        t) BASE_TAG="${OPTARG}" ;;
        x) RUN_TESTS=false ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

command -v jq >/dev/null || { echo "Please install jq" >&2; exit 1; }

# The cherry-picks below need a committer to write commits with, and CI runners
# carry no git identity. The author of each commit is preserved from the patch,
# and these commits never leave target-custom-image/.
: "${GIT_COMMITTER_NAME:=custom image build}"
: "${GIT_COMMITTER_EMAIL:=custom-image-build@audiense.com}"
export GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

config() { jq -r "$1" "${CONFIG}"; }

[ -n "${BASE_TAG}" ] || BASE_TAG="$(config '.baseTag')"
UPSTREAM_URL="$(config '.upstreamRemoteUrl')"
BASE_IMAGE="$(config '.image.baseRepository // "trinodb/trino"'):${BASE_TAG}"
mapfile -t PLUGINS < <(config '.plugins[]')
mapfile -t EXTRA_MODULES < <(config '.extraModules[] // empty')

echo "==> Building on Trino ${BASE_TAG}"

# The fork does not carry upstream's release tags, so fetch the tag from upstream.
# Named "upstream-releases" to avoid clashing with whatever a developer has set up.
if ! git -C "${REPO_ROOT}" config --get remote.upstream-releases.url >/dev/null; then
    git -C "${REPO_ROOT}" remote add upstream-releases "${UPSTREAM_URL}"
fi
git -C "${REPO_ROOT}" fetch --quiet upstream-releases "refs/tags/${BASE_TAG}:refs/tags/${BASE_TAG}" 2>/dev/null \
    || git -C "${REPO_ROOT}" rev-parse --verify --quiet "refs/tags/${BASE_TAG}" >/dev/null \
    || { echo "Trino release tag ${BASE_TAG} not found upstream" >&2; exit 1; }

echo "==> Preparing a clean worktree at ${SRC_DIR}"
git -C "${REPO_ROOT}" worktree remove --force "${SRC_DIR}" 2>/dev/null || true
rm -rf "${BUILD_DIR}"
# A worktree directory removed by hand stays registered, and git then refuses to
# delete the branch it had checked out. Runners with reusable capacity carry that
# state over from the previous build.
git -C "${REPO_ROOT}" worktree prune
git -C "${REPO_ROOT}" branch -D "${WORK_BRANCH}" 2>/dev/null || true
git -C "${REPO_ROOT}" worktree add --quiet -b "${WORK_BRANCH}" "${SRC_DIR}" "refs/tags/${BASE_TAG}"

echo "==> Applying patches"
patch_count="$(config '.patches | length')"
for i in $(seq 0 $((patch_count - 1))); do
    pr="$(config ".patches[${i}].pr")"
    title="$(config ".patches[${i}].title")"
    # A port overrides the branch when the plain cherry-pick does not apply to this release.
    ref="$(config ".patches[${i}].ports.\"${BASE_TAG}\" // .patches[${i}].ref")"

    git -C "${REPO_ROOT}" rev-parse --verify --quiet "${ref}" >/dev/null \
        || { echo "PR #${pr}: ref ${ref} does not exist. Fetch it first." >&2; exit 1; }

    # The patch branches are rebased onto upstream master, so the commits that
    # belong to the PR are the ones after the point where the branch forked off.
    base="$(git -C "${SRC_DIR}" merge-base "${ref}" upstream-releases/master 2>/dev/null || true)"
    if [ -z "${base}" ]; then
        git -C "${REPO_ROOT}" fetch --quiet upstream-releases master
        base="$(git -C "${SRC_DIR}" merge-base "${ref}" upstream-releases/master)"
    fi
    mapfile -t commits < <(git -C "${SRC_DIR}" rev-list --reverse "${base}..${ref}")
    [ ${#commits[@]} -gt 0 ] || { echo "PR #${pr}: ${ref} carries no commits over upstream master" >&2; exit 1; }

    echo "    #${pr} ${title} (${#commits[@]} commits from ${ref})"
    if ! cherry_pick_output="$(git -C "${SRC_DIR}" cherry-pick "${commits[@]}" 2>&1)"; then
        conflicts="$(git -C "${SRC_DIR}" diff --name-only --diff-filter=U)"
        git -C "${SRC_DIR}" cherry-pick --abort 2>/dev/null || true
        if [ -z "${conflicts}" ]; then
            # Not a conflict: git itself refused. Say so rather than sending the
            # reader off to resolve a conflict that does not exist.
            echo >&2
            echo "PR #${pr} could not be applied to ${BASE_TAG}:" >&2
            echo "${cherry_pick_output}" | sed 's/^/    /' >&2
            exit 1
        fi
        cat >&2 <<EOF

PR #${pr} does not apply cleanly to ${BASE_TAG}. Conflicting files:
$(echo "${conflicts}" | sed 's/^/    /')

Resolve it once against the release and record the result, so that every later
build of ${BASE_TAG} reuses it:

    git checkout -b <alias>/<topic>-${BASE_TAG} refs/tags/${BASE_TAG}
    git cherry-pick ${commits[*]}
    # resolve, then push the branch

then add it to .audiense/custom-image.json:

    "ports": { "${BASE_TAG}": "origin/<alias>/<topic>-${BASE_TAG}" }
EOF
        exit 1
    fi
done

MODULES="$(IFS=,; echo "${PLUGINS[*]}")"

# No -am anywhere below: at a release tag every module version is exact, so
# everything the connectors depend on resolves from Maven Central. Only the few
# modules Trino does not publish there have to be built, which is what
# extraModules is for; installing them first keeps them out of the plugin builds.
if [ ${#EXTRA_MODULES[@]} -gt 0 ]; then
    echo "==> Installing modules Trino does not publish: ${EXTRA_MODULES[*]}"
    (cd "${SRC_DIR}" && MAVEN_OPTS="-Xmx3G" ./mvnw install -pl "$(IFS=,; echo "${EXTRA_MODULES[*]}")" \
        -DskipTests -Dair.check.skip-all=true)
fi

if [ "${RUN_TESTS}" = true ]; then
    for plugin in "${PLUGINS[@]}"; do
        extra_args=()
        mapfile -t extra_args < <(config ".testArgs.\"${plugin}\"[]? // empty")
        echo "==> Testing ${plugin} ${extra_args[*]-}"
        (cd "${SRC_DIR}" && MAVEN_OPTS="-Xmx3G" ./mvnw test -pl "${plugin}" \
            -Dair.check.skip-all=true ${extra_args[@]+"${extra_args[@]}"})
    done
fi

echo "==> Packaging ${MODULES}"
(cd "${SRC_DIR}" && MAVEN_OPTS="-Xmx3G" ./mvnw package -pl "${MODULES}" -DskipTests -Dair.check.skip-all=true)

echo "==> Assembling the build context"
mkdir -p "${CONTEXT_DIR}/plugins"
cp "${SCRIPT_DIR}/Dockerfile" "${CONTEXT_DIR}/Dockerfile"
for plugin in "${PLUGINS[@]}"; do
    artifact="$(basename "${plugin}")"
    # trino-opensearch is installed as /usr/lib/trino/plugin/opensearch
    name="${artifact#trino-}"
    built="${SRC_DIR}/${plugin}/target/${artifact}-${BASE_TAG}"
    [ -d "${built}" ] || { echo "Expected ${built} to exist" >&2; exit 1; }
    cp -R "${built}" "${CONTEXT_DIR}/plugins/${name}"
    echo "    ${name}: $(ls "${CONTEXT_DIR}/plugins/${name}" | wc -l | tr -d ' ') jars"
done

# COPY merges, so a jar the official image ships and we no longer produce would
# survive next to ours and put two versions of a library on the plugin classpath.
#
# Only the flat jars are ours. A plugin directory is assembled from more than the
# connector artifact: core/trino-server/src/main/provisio/trino.xml also unpacks
# trino-hdfs with its root into iceberg, hive and delta-lake, which is where the
# nested hdfs/ classloader comes from. Those subdirectories belong to the release
# and are meant to survive untouched.
echo "==> Checking for jars the official image ships that this build does not"
orphans=0
for plugin in "${PLUGINS[@]}"; do
    name="$(basename "${plugin}")"; name="${name#trino-}"
    official="$(docker run --rm --entrypoint sh "${BASE_IMAGE}" -c "find /usr/lib/trino/plugin/${name} -maxdepth 1 -type f -printf '%f\\n'")"
    left_behind="$(comm -23 <(echo "${official}" | sort) <(find "${CONTEXT_DIR}/plugins/${name}" -maxdepth 1 -type f -printf '%f\n' | sort))"
    if [ -n "${left_behind}" ]; then
        echo "    ${name} would keep stale jars:" >&2
        echo "${left_behind}" | sed 's/^/        /' >&2
        orphans=1
    fi
done
[ "${orphans}" -eq 0 ] || {
    echo "
A patch changed the connector's dependencies. Copying over the official plugin
directory is no longer enough; the directory has to be replaced instead." >&2
    exit 1
}

# Name the image after what went into it. The tree hash covers the release and
# every patch applied on top, so the same inputs always produce the same tag and
# any change produces a new one. Commit shas would not do: rebasing a patch
# branch rewrites them without changing a line of the result.
#
# The repository holds mirrored upstream tags too and is IMMUTABLE, so a tag that
# did not move with its contents could not be pushed a second time.
TAG_SUFFIX="$(config '.image.tagSuffix')"
PATCHSET="$(git -C "${SRC_DIR}" rev-parse 'HEAD^{tree}' | cut -c1-8)"
IMAGE_TAG="${BASE_TAG}-${TAG_SUFFIX}-${PATCHSET}"
echo "${IMAGE_TAG}" > "${BUILD_DIR}/image-tag"

echo
echo "Build context ready at ${CONTEXT_DIR}"
echo "Base image ${BASE_IMAGE}"
echo "Built from ${BASE_TAG} with $(git -C "${SRC_DIR}" rev-list --count "refs/tags/${BASE_TAG}..HEAD") patch commits"
echo "Image tag ${IMAGE_TAG}"
