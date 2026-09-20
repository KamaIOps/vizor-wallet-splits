#!/usr/bin/env bash
# Regenerates the Dart bridge.
#
# `flutter_rust_bridge_codegen generate` reads `cargo expand`'s output with
# `syn`, and rustc 1.98 prints two things `syn` cannot parse:
#
#   #[unsafe(no_mangle)]   the Rust 2024 spelling of `#[no_mangle]`
#   super let              what `pin!()` expands to
#
# Both stop the generator with `unexpected token, expected ';'` and neither is
# anything it looks at: it reads function signatures out of `crate::api` and
# never compiles the expansion. This puts a `cargo` in front of it that
# rewrites the two to their ordinary forms on the way past.
#
# The second one is not a version problem to wait out — no released `syn`
# parses `super let`, including the newest.
#
# Usage: tool/frb-generate.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
real_cargo="$(command -v cargo)"
shim="$(mktemp -d)"
trap 'rm -rf "$shim"' EXIT

cat > "$shim/cargo" <<SHIM
#!/usr/bin/env bash
if [ "\$1" = "expand" ]; then
  "$real_cargo" "\$@" | sed -e 's/#\[unsafe(no_mangle)\]/#[no_mangle]/g' -e 's/super let /let /g'
  exit \${PIPESTATUS[0]}
fi
exec "$real_cargo" "\$@"
SHIM
chmod +x "$shim/cargo"

cd "$root"
PATH="$shim:$PATH" flutter_rust_bridge_codegen generate "$@"
