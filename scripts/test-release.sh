#!/usr/bin/env bash
# Tests for release.sh in a throwaway sandbox: fake plugin repos with local bare remotes.
# Run: scripts/test-release.sh   (needs jq, git; the "resulting marketplace" check needs claude)
set -u
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "${T:?}"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✔ $*"; }
ko()  { FAIL=$((FAIL+1)); echo "  ✘ $*"; }
expect_fail() { local msg="$1"; shift; if out="$("$@" 2>&1)"; then ko "$msg (should have failed)"; else echo "$out" | grep -q "$EXP" && ok "$msg: $(echo "$out" | tail -1)" || ko "$msg: wrong error: $out"; fi; }
G() { git -c user.email=t@t -c user.name=t "$@"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

mkdir -p "$T/remotes"
cp -R "$SRC" "$T/market"; rm -rf "$T/market/.git"
git -C "$T/market" init -q -b main && git -C "$T/market" add -A && git -C "$T/market" commit -qm init
git init -q --bare "$T/remotes/market.git" && git -C "$T/market" remote add origin "$T/remotes/market.git" && git -C "$T/market" push -q origin main
R="$T/market/scripts/release.sh"
M="$T/market/.claude-plugin/marketplace.json"

mkplugin() { # name version [with-local-market]
  local d="$T/$1"; mkdir -p "$d/.claude-plugin" "$d/skills/$1"
  printf -- '---\nname: %s\ndescription: test\n---\nbody\n' "$1" > "$d/skills/$1/SKILL.md"
  git -C "$d" init -q -b main; git -C "$d" add skills; git -C "$d" commit -qm init
  printf '{"name":"%s","description":"%s desc","version":"%s"}\n' "$1" "$1" "$2" > "$d/.claude-plugin/plugin.json"
  if [ -n "${3:-}" ]; then
    printf '{"name":"%s-mp","owner":{"name":"t"},"metadata":{"version":"%s"},"plugins":[{"name":"%s","source":"./","version":"%s"}]}\n' "$1" "$2" "$1" "$2" > "$d/.claude-plugin/marketplace.json"
    git -C "$d" add .claude-plugin; git -C "$d" commit -qm manifests   # tracked, like yt-lokus
  fi
  git init -q --bare "$T/remotes/$1.git"; git -C "$d" remote add origin "$T/remotes/$1.git"; git -C "$d" push -q origin main
}

echo "1. first release, untracked plugin.json at same version (svg-craft case)"
mkplugin alpha 0.1.0
before="$(shasum "$M")"
"$R" --dry-run "$T/alpha" 0.1.0 >/dev/null && [ "$before" = "$(shasum "$M")" ] && [ -z "$(git -C "$T/alpha" tag)" ] && ok "dry-run wrote nothing" || ko "dry-run changed something"
"$R" "$T/alpha" 0.1.0 | tail -1
git -C "$T/remotes/alpha.git" rev-parse -q --verify refs/tags/v0.1.0 >/dev/null && ok "tag pushed" || ko "tag not pushed"
git -C "$T/alpha" ls-files --error-unmatch .claude-plugin/plugin.json >/dev/null 2>&1 && ok "plugin.json committed" || ko "plugin.json not committed"
[ "$(jq -r '.plugins[0].source.sha' "$M")" = "$(git -C "$T/alpha" rev-parse 'v0.1.0^{commit}')" ] && ok "sha pinned = tag commit" || ko "sha mismatch"
[ "$(jq -r .metadata.version "$M")" = 0.2.0 ] && ok "new plugin → marketplace minor (0.2.0)" || ko "marketplace version $(jq -r .metadata.version "$M")"
git -C "$T/remotes/market.git" rev-parse -q --verify refs/tags/v0.2.0 >/dev/null && ok "marketplace tag pushed" || ko "marketplace tag missing"

echo "2. patch bump"
"$R" "$T/alpha" 0.1.1 | tail -1
[ "$(jq -r .version "$T/alpha/.claude-plugin/plugin.json")" = 0.1.1 ] && [ "$(jq -r '.plugins[0].source.ref' "$M")" = v0.1.1 ] && [ "$(jq -r .metadata.version "$M")" = 0.2.1 ] && ok "plugin 0.1.1, ref v0.1.1, marketplace 0.2.1" || ko "patch bump wrong"
[ "$(git -C "$T/remotes/alpha.git" rev-parse main)" = "$(git -C "$T/alpha" rev-parse HEAD)" ] && ok "bump commit pushed" || ko "branch not pushed"

echo "3. major bump"
"$R" "$T/alpha" 1.0.0 | tail -1
[ "$(jq -r .metadata.version "$M")" = 0.3.0 ] && ok "major plugin bump → marketplace minor (0.3.0)" || ko "got $(jq -r .metadata.version "$M")"

echo "4. pin an existing tag (anti-drift-auto case), with a local marketplace.json"
mkplugin beta 0.4.0 local
git -C "$T/beta" tag -a v0.4.0 -m x; git -C "$T/beta" push -q origin v0.4.0
head_before="$(git -C "$T/beta" rev-parse HEAD)"
"$R" "$T/beta" 0.4.0 | tail -1
[ "$head_before" = "$(git -C "$T/beta" rev-parse HEAD)" ] && ok "no commit in plugin repo" || ko "plugin repo touched"
[ "$(jq -r '.plugins[] | select(.name=="beta") | .source.ref' "$M")" = v0.4.0 ] && ok "beta pinned at v0.4.0" || ko "beta not pinned"
"$R" "$T/beta" 0.4.0 | grep -q "nothing to do" && ok "idempotent re-run" || ko "re-run not idempotent"

echo "5. local marketplace.json kept in sync"
"$R" "$T/beta" 0.5.0 >/dev/null
[ "$(jq -r '.metadata.version + " " + .plugins[0].version' "$T/beta/.claude-plugin/marketplace.json")" = "0.5.0 0.5.0" ] && ok "local marketplace.json at 0.5.0" || ko "local marketplace not synced"

echo "6. refusals"
EXP="not above"; expect_fail "lower version" "$R" "$T/alpha" 0.9.0
EXP="X.Y.Z"; expect_fail "bad version" "$R" "$T/alpha" 1.1
git -C "$T/alpha" checkout -qb feat; EXP="branch 'feat'"; expect_fail "feature branch" "$R" "$T/alpha" 1.0.1
"$R" --allow-branch --no-push "$T/alpha" 1.0.1 >/dev/null && ok "--allow-branch --no-push works" || ko "--allow-branch failed"
git -C "$T/remotes/alpha.git" rev-parse -q --verify refs/tags/v1.0.1 >/dev/null && ko "--no-push pushed the tag" || ok "--no-push kept the tag local"
git -C "$T/alpha" checkout -q main
echo dirty >> "$T/alpha/skills/alpha/SKILL.md"; EXP="uncommitted"; expect_fail "dirty plugin repo" "$R" "$T/alpha" 1.1.0
git -C "$T/alpha" checkout -q -- skills
mkdir -p "$T/gamma/.claude-plugin"; git -C "$T/gamma" init -q -b main; echo '{"name":"gamma","version":"0.1.0"}' > "$T/gamma/.claude-plugin/plugin.json"
EXP="no commit yet"; expect_fail "empty repo" "$R" "$T/gamma" 0.1.0
G -C "$T/gamma" add -A; G -C "$T/gamma" commit -qm i; EXP="no 'origin'"; expect_fail "no remote" "$R" "$T/gamma" 0.1.0
git -C "$T/beta" tag -a v9.9.9 -m x; EXP="its plugin.json says"; expect_fail "tag/version mismatch" "$R" "$T/beta" 9.9.9

echo "7. resulting marketplace"
claude plugin validate "$T/market" 2>&1 | grep -E '✔|✘|⚠' | head -5
sed -n '1,14p' "$T/market/CHANGELOG.md"
echo "RESULT: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
