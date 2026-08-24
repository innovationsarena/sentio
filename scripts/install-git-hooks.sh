#!/usr/bin/env bash
# Installs a pre-push hook that runs the two checks CI fails on most often.
# Catching them here costs seconds; catching them on a runner costs minutes and
# a red mark on the branch.
#
#   ./scripts/install-git-hooks.sh
#
# Skip it for one push with `git push --no-verify`.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
hook="$root/.git/hooks/pre-push"

cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
echo "pre-push: cargo fmt --check"
cargo fmt --all -- --check
echo "pre-push: cargo clippy"
cargo clippy --workspace --all-targets -- -D warnings
HOOK

chmod +x "$hook"
echo "installed $hook"
