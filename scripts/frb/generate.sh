#!/usr/bin/env bash
# Regenerates the Rust bridge: lib/src/rust/** and rust/src/frb_generated.rs.
#
#     scripts/frb/generate.sh
#
# flutter_rust_bridge_codegen 2.11.1 (the runtime is pinned to =2.11.1), under
# Rust 1.91: the dependencies need 1.91, and the generator's parser cannot read
# what newer toolchains expand `pin!` to — see ./cargo. rustfmt must be
# installed for that toolchain or rust/src/frb_generated.rs comes out
# unformatted:
#
#     rustup toolchain install 1.91 --profile minimal
#     rustup component add --toolchain 1.91 rustfmt
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/../.."
PATH="$here:$PATH" rustup run 1.91 flutter_rust_bridge_codegen generate
