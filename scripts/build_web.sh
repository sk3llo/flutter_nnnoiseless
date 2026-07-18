#!/usr/bin/env bash
# Builds the WebAssembly bundle for flutter_nnnoiseless into web/pkg.
#
# Requirements:
#   rustup toolchain install nightly --component rust-src --target wasm32-unknown-unknown
#   cargo install wasm-bindgen-cli --version <version in rust/Cargo.lock>
#
# The nightly + build-std dance is required because the wasm runs with
# threading (flutter_rust_bridge dispatches calls to a Web Worker pool),
# which needs shared memory and an atomics-enabled std.
set -euo pipefail

cd "$(dirname "$0")/.."

WBG_VERSION=$(grep -A1 'name = "wasm-bindgen"' rust/Cargo.lock | grep version | head -1 | cut -d'"' -f2)
if ! wasm-bindgen --version 2>/dev/null | grep -q "$WBG_VERSION"; then
  echo "Installing wasm-bindgen-cli $WBG_VERSION (must match rust/Cargo.lock)..."
  cargo install wasm-bindgen-cli --version "$WBG_VERSION" --locked
fi

export RUSTUP_TOOLCHAIN=nightly
export RUSTFLAGS='-C target-feature=+atomics,+bulk-memory,+mutable-globals -C link-arg=--import-memory -C link-arg=--shared-memory -C link-arg=--max-memory=1073741824 -C link-arg=--export=__heap_base -C link-arg=--export=__tls_base -C link-arg=--export=__wasm_init_tls -C link-arg=--export=__tls_size -C link-arg=--export=__tls_align'

cargo build \
  --manifest-path rust/Cargo.toml \
  --target wasm32-unknown-unknown \
  --release \
  -Z build-std=std,panic_abort

wasm-bindgen rust/target/wasm32-unknown-unknown/release/rust_lib_flutter_nnnoiseless.wasm \
  --out-dir web/pkg \
  --target no-modules \
  --no-typescript \
  --out-name rust_lib_flutter_nnnoiseless

# wasm-pack would normally do this; the stray .gitignore ("*") must not ship,
# because pub excludes gitignored files from the package.
rm -f web/pkg/.gitignore

echo "Done: $(ls -la web/pkg/rust_lib_flutter_nnnoiseless_bg.wasm | awk '{print $5}') bytes"
