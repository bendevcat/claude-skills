#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq filters: $vars are jq variables, not shell ones
# Release one plugin from its own repository and pin it in this marketplace.
#
#   scripts/release.sh [--dry-run] [--no-push] [--allow-branch] <plugin-repo> <X.Y.Z>
#
# In the plugin repository:
#   1. bumps .claude-plugin/plugin.json to X.Y.Z (and its own marketplace.json, if it has one),
#   2. commits that, tags vX.Y.Z, pushes the branch and the tag.
#   If vX.Y.Z already exists, nothing is changed there: the tag is only pinned (useful for
#   a release made by hand, e.g. anti-drift-auto v0.4.0).
# In this marketplace:
#   3. adds or updates the plugin entry: source = git url + ref vX.Y.Z + sha of that commit,
#   4. bumps metadata.version, adds a CHANGELOG line, commits, tags v<marketplace version>, pushes.
#
# --dry-run       print what would happen, change nothing
# --no-push       commit and tag locally, push nothing
# --allow-branch  release from a branch other than main/master

set -euo pipefail

MARKET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$MARKET_DIR/.claude-plugin/marketplace.json"
CHANGELOG="$MARKET_DIR/CHANGELOG.md"

die()  { printf '✘ %s\n' "$*" >&2; exit 1; }
info() { printf '▸ %s\n' "$*"; }
usage() { sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

DRY_RUN=0; PUSH=1; ALLOW_BRANCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-push) PUSH=0 ;;
    --allow-branch) ALLOW_BRANCH=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
  shift
done
[ $# -eq 2 ] || { usage; exit 2; }

command -v jq >/dev/null || die "jq is required (brew install jq)"
[ -d "$1" ] || die "not a directory: $1"
REPO="$(cd "$1" && pwd)"
VERSION="$2"
TAG="v$VERSION"
PLUGIN_JSON="$REPO/.claude-plugin/plugin.json"
LOCAL_MARKET="$REPO/.claude-plugin/marketplace.json"

# run CMD...: execute, or only print it in --dry-run.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then printf '  (dry-run) %s\n' "$*"; else "$@"; fi
}

# jq_inplace FILE FILTER [jq args...]: rewrite FILE through a jq filter.
jq_inplace() {
  local file="$1" filter="$2"; shift 2
  if [ "$DRY_RUN" -eq 1 ]; then printf '  (dry-run) jq %s > %s\n' "$filter" "$file"; return; fi
  local tmp; tmp="$(mktemp)"
  jq "$@" "$filter" "$file" > "$tmp" && mv "$tmp" "$file"
}

# semver_cmp A B: prints -1, 0 or 1.
semver_cmp() {
  local IFS=.
  # shellcheck disable=SC2206
  local a=($1) b=($2) i
  for i in 0 1 2; do
    if [ "${a[$i]}" -lt "${b[$i]}" ]; then echo -1; return; fi
    if [ "${a[$i]}" -gt "${b[$i]}" ]; then echo 1; return; fi
  done
  echo 0
}

# bump_semver X.Y.Z major|minor|patch
bump_semver() {
  local IFS=.
  # shellcheck disable=SC2206
  local v=($1)
  case "$2" in
    major) echo "$((v[0] + 1)).0.0" ;;
    minor) echo "${v[0]}.$((v[1] + 1)).0" ;;
    patch) echo "${v[0]}.${v[1]}.$((v[2] + 1))" ;;
  esac
}

# How much the marketplace version moves for this release.
#   is_new: 1 when the plugin enters the catalog
#   old_ref: the tag the catalog pinned before ("" when new), new_ref: the tag pinned now
# A plugin entering the catalog, or a plugin crossing a major version, is a minor change
# of the catalog; any other move is a patch.
marketplace_bump_kind() {
  local is_new="$1" old_ref="$2" new_ref="$3"
  if [ "$is_new" -eq 1 ]; then echo minor; return; fi
  if [ "${old_ref#v}" != "$old_ref" ] && [ "${old_ref#v}" != "" ]; then
    local old_major="${old_ref#v}"; old_major="${old_major%%.*}"
    local new_major="${new_ref#v}"; new_major="${new_major%%.*}"
    if [ "$old_major" != "$new_major" ]; then echo minor; return; fi
  fi
  echo patch
}

# https form of a git remote, so anyone can clone the pinned source.
public_url() {
  case "$1" in
    git@github.com:*) echo "https://github.com/${1#git@github.com:}" ;;
    ssh://git@github.com/*) echo "https://github.com/${1#ssh://git@github.com/}" ;;
    *) echo "$1" ;;
  esac
}

# ---------------------------------------------------------------- checks
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z, got: $VERSION"
[ -f "$PLUGIN_JSON" ] || die "no .claude-plugin/plugin.json in $REPO"
[ -f "$MANIFEST" ] || die "no marketplace manifest at $MANIFEST"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "$REPO is not a git repository"
git -C "$REPO" rev-parse -q --verify HEAD >/dev/null || die "$REPO has no commit yet"

NAME="$(jq -r .name "$PLUGIN_JSON")"
CURRENT="$(jq -r '.version // "0.0.0"' "$PLUGIN_JSON")"
[ -n "$NAME" ] && [ "$NAME" != null ] || die "plugin.json has no name"

BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
case "$BRANCH" in
  main|master) ;;
  *) [ "$ALLOW_BRANCH" -eq 1 ] || die "$NAME is on branch '$BRANCH': merge into main first, or pass --allow-branch" ;;
esac

REMOTE_URL="$(git -C "$REPO" remote get-url origin 2>/dev/null)" \
  || die "$NAME has no 'origin' remote: create the repository and push it first"
SOURCE_URL="$(public_url "$REMOTE_URL")"

[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] \
  || die "$NAME has uncommitted changes to tracked files: commit or set them aside first"
[ -z "$(git -C "$MARKET_DIR" status --porcelain --untracked-files=no)" ] \
  || die "the marketplace repository has uncommitted changes"

info "$NAME: $CURRENT → $VERSION   (branch $BRANCH, $SOURCE_URL)"
[ "$DRY_RUN" -eq 1 ] && info "dry run: nothing will be written"

# ---------------------------------------------------------------- plugin repository
if git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  TAGGED="$(git -C "$REPO" show "$TAG:.claude-plugin/plugin.json" 2>/dev/null | jq -r .version)" \
    || die "$TAG exists but has no .claude-plugin/plugin.json"
  [ "$TAGGED" = "$VERSION" ] || die "$TAG exists but its plugin.json says $TAGGED"
  info "$TAG already exists: pinning it as is"
else
  if [ "$VERSION" != "$CURRENT" ]; then
    [ "$(semver_cmp "$VERSION" "$CURRENT")" = 1 ] || die "$VERSION is not above the current $CURRENT"
    jq_inplace "$PLUGIN_JSON" '.version = $v' --arg v "$VERSION"
    if [ -f "$LOCAL_MARKET" ]; then
      jq_inplace "$LOCAL_MARKET" \
        '.metadata.version = $v | .plugins |= map(if .name == $n then .version = $v else . end)' \
        --arg v "$VERSION" --arg n "$NAME"
    fi
  fi
  # Commit the manifests if they changed or were never committed (first release).
  FILES=(.claude-plugin/plugin.json)
  [ -f "$LOCAL_MARKET" ] && FILES+=(.claude-plugin/marketplace.json)
  if { [ "$DRY_RUN" -eq 1 ] && [ "$VERSION" != "$CURRENT" ]; } \
     || [ -n "$(git -C "$REPO" status --porcelain -- "${FILES[@]}")" ]; then
    run git -C "$REPO" add -- "${FILES[@]}"
    run git -C "$REPO" commit -q -m "release: $TAG" -- "${FILES[@]}"
  fi
  run git -C "$REPO" tag -a "$TAG" -m "$NAME $TAG"
  if [ "$PUSH" -eq 1 ]; then
    run git -C "$REPO" push -q origin "$BRANCH"
    run git -C "$REPO" push -q origin "$TAG"
  fi
fi

if [ "$DRY_RUN" -eq 1 ] && ! git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  SHA="(new $TAG)"
else
  SHA="$(git -C "$REPO" rev-parse "$TAG^{commit}")"
fi

# ---------------------------------------------------------------- marketplace
OLD_REF="$(jq -r --arg n "$NAME" '.plugins[] | select(.name == $n) | .source.ref // ""' "$MANIFEST")"
OLD_SHA="$(jq -r --arg n "$NAME" '.plugins[] | select(.name == $n) | .source.sha // ""' "$MANIFEST")"
IS_NEW=0
[ -n "$(jq -r --arg n "$NAME" '.plugins[] | select(.name == $n) | .name' "$MANIFEST")" ] || IS_NEW=1

if [ "$IS_NEW" -eq 0 ] && [ "$OLD_REF" = "$TAG" ] && [ "$OLD_SHA" = "$SHA" ]; then
  info "the marketplace already pins $NAME at $TAG: nothing to do"
  exit 0
fi

MARKET_OLD="$(jq -r '.metadata.version' "$MANIFEST")"
MARKET_NEW="$(bump_semver "$MARKET_OLD" "$(marketplace_bump_kind "$IS_NEW" "$OLD_REF" "$TAG")")"
if [ "$DRY_RUN" -eq 1 ] && ! git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  DESCRIPTION="$(jq -r '.description // ""' "$PLUGIN_JSON")"
else
  DESCRIPTION="$(git -C "$REPO" show "$TAG:.claude-plugin/plugin.json" | jq -r '.description // ""')"
fi

jq_inplace "$MANIFEST" '
  .metadata.version = $mv
  | ({source: "url", url: $url, ref: $ref, sha: $sha}) as $src
  | if any(.plugins[]; .name == $n)
    then .plugins |= map(if .name == $n then .source = $src | .description = $d else . end)
    else .plugins += [{name: $n, description: $d, source: $src}]
    end' \
  --arg mv "$MARKET_NEW" --arg n "$NAME" --arg d "$DESCRIPTION" \
  --arg url "$SOURCE_URL" --arg ref "$TAG" --arg sha "$SHA"

if [ "$IS_NEW" -eq 1 ]; then LINE="- $NAME added at $TAG."; else LINE="- $NAME: ${OLD_REF:-?} → $TAG."; fi
if [ "$DRY_RUN" -eq 1 ]; then
  printf '  (dry-run) CHANGELOG: ## %s / %s\n' "$MARKET_NEW" "$LINE"
else
  tmp="$(mktemp)"
  awk -v head="## $MARKET_NEW" -v line="$LINE" '
    !done && /^## / { print head "\n\n" line "\n"; done = 1 }
    { print }
    END { if (!done) print "\n" head "\n\n" line }' "$CHANGELOG" > "$tmp" && mv "$tmp" "$CHANGELOG"
fi

run git -C "$MARKET_DIR" add -- .claude-plugin/marketplace.json CHANGELOG.md
run git -C "$MARKET_DIR" commit -q -m "release($NAME): $TAG" -- .claude-plugin/marketplace.json CHANGELOG.md
run git -C "$MARKET_DIR" tag -a "v$MARKET_NEW" -m "marketplace v$MARKET_NEW: $NAME $TAG"
if [ "$PUSH" -eq 1 ]; then
  if git -C "$MARKET_DIR" remote get-url origin >/dev/null 2>&1; then
    run git -C "$MARKET_DIR" push -q origin HEAD
    run git -C "$MARKET_DIR" push -q origin "v$MARKET_NEW"
  else
    info "the marketplace has no 'origin' remote yet: commit and tag are local"
  fi
fi

info "done: $NAME $TAG pinned at $(printf "%.12s" "$SHA"), marketplace $MARKET_OLD → $MARKET_NEW"
