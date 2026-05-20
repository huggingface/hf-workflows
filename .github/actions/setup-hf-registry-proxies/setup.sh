#!/usr/bin/env bash
# setup-registry-proxies.sh
#
# Configure local package managers (npm, pnpm, yarn, pip, uv, cargo, conda) to
# use the HuggingFace internal caching proxies, which hold back package versions
# younger than 3 days to defend against supply-chain attacks.
#
# Background + architecture:
#   https://www.notion.so/huggingface2/Internal-Package-Registry-Proxies-3641384ebcac8199b610c4f98f376986
#
# Requires the corp VPN (group app-vpn-infra-tooling@huggingface.co).
#
# Usage:
#   curl -sSL https://pypi.registries.huggingface.tech/setup.sh | bash
#
# Or from a local clone:
#   bash projects/shared-infra/terraform/20-package-proxies/package-proxy/setup.sh

set -euo pipefail

NPM_URL="https://npm.registries.huggingface.tech/"
PYPI_URL="https://pypi.registries.huggingface.tech/"
CARGO_URL="https://cargo.registries.huggingface.tech/"
CONDA_URL="https://conda.registries.huggingface.tech/"
GO_URL="https://go.registries.huggingface.tech"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""
fi

info()  { printf '%s==>%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
ok()    { printf '%s ok%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn()  { printf '%swarn%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
err()   { printf '%sfail%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
skip()  { printf '%sskip%s %s\n' "$C_DIM" "$C_RESET" "$*"; }

# Portable in-place sed wrapper. BSD sed (macOS) requires an empty backup
# extension after -i; GNU sed (Linux) does not.
sed_inplace() {
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

backup_file() {
  local f=$1
  [[ -f $f ]] || return 0
  local bak="${f}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$f" "$bak"
  printf '%s     backed up %s -> %s%s\n' "$C_DIM" "$f" "$bak" "$C_RESET"
}

# Replace or append a `key=value` line in a flat config file (npm, ini-ish).
upsert_line() {
  local file=$1 key=$2 value=$3
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if grep -qE "^${key}[[:space:]]*=" "$file"; then
    sed_inplace -E "s|^${key}[[:space:]]*=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

# Replace text between sentinel comments, or append the block if absent.
upsert_block() {
  local file=$1 block=$2
  mkdir -p "$(dirname "$file")"
  if [[ -f $file ]]; then
    awk '
      /^# >>> hf-registry-proxy >>>$/ { skipping=1; next }
      /^# <<< hf-registry-proxy <<<$/ { skipping=0; next }
      !skipping { print }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  else
    : > "$file"
  fi
  {
    printf '# >>> hf-registry-proxy >>>\n'
    printf '%s\n' "$block"
    printf '# <<< hf-registry-proxy <<<\n'
  } >> "$file"
}

check_vpn() {
  info "Checking VPN reachability to proxies"
  local fail=0
  for url in "$NPM_URL" "$PYPI_URL" "$CARGO_URL" "$CONDA_URL" "$GO_URL/"; do
    if curl -fsS --max-time 4 -o /dev/null "${url%/}/-/ping"; then
      ok "reachable: $url"
    else
      err "unreachable: $url"
      fail=1
    fi
  done
  if (( fail )); then
    err "One or more proxies are unreachable. Connect the VPN (app-vpn-infra-tooling@huggingface.co) and retry."
    exit 1
  fi
}

setup_npm() {
  if ! command -v npm >/dev/null 2>&1 && ! command -v pnpm >/dev/null 2>&1; then
    skip "npm/pnpm not installed"
    return 0
  fi
  info "Configuring npm/pnpm (~/.npmrc)"
  local f="$HOME/.npmrc"
  backup_file "$f"
  upsert_line "$f" "registry" "$NPM_URL"
  upsert_line "$f" "ignore-scripts" "true"
  ok "wrote registry + ignore-scripts to $f"
}

setup_yarn_classic() {
  command -v yarn >/dev/null 2>&1 || { skip "yarn not installed"; return 0; }
  local ver
  ver=$(yarn --version 2>/dev/null || true)
  if [[ -z $ver || ${ver%%.*} -ge 2 ]]; then
    skip "yarn $ver detected — berry uses per-project .yarnrc.yml, leaving alone"
    return 0
  fi
  info "Configuring yarn classic (~/.yarnrc)"
  local f="$HOME/.yarnrc"
  backup_file "$f"
  if grep -qE '^registry[[:space:]]+' "$f" 2>/dev/null; then
    sed_inplace -E "s|^registry[[:space:]]+.*|registry \"$NPM_URL\"|" "$f"
  else
    printf 'registry "%s"\n' "$NPM_URL" >> "$f"
  fi
  ok "wrote registry to $f"
}

setup_pip() {
  command -v pip >/dev/null 2>&1 || command -v pip3 >/dev/null 2>&1 || { skip "pip not installed"; return 0; }
  # XDG path is the current standard (pip docs); ~/.pip/pip.conf is the legacy
  # fallback. We write the XDG one unless the legacy file already exists.
  local f="$HOME/.config/pip/pip.conf"
  if [[ -f "$HOME/.pip/pip.conf" && ! -f "$f" ]]; then
    f="$HOME/.pip/pip.conf"
  fi
  info "Configuring pip ($f)"
  mkdir -p "$(dirname "$f")"
  backup_file "$f"
  if [[ ! -f $f ]]; then
    printf '[global]\nindex-url = %s\n' "$PYPI_URL" > "$f"
  elif grep -qE '^\[global\]' "$f"; then
    if grep -qE '^[[:space:]]*index-url[[:space:]]*=' "$f"; then
      sed_inplace -E "s|^[[:space:]]*index-url[[:space:]]*=.*|index-url = $PYPI_URL|" "$f"
    else
      sed_inplace -E "/^\[global\]/a\\
index-url = $PYPI_URL
" "$f"
    fi
  else
    printf '\n[global]\nindex-url = %s\n' "$PYPI_URL" >> "$f"
  fi
  ok "wrote index-url to $f"
}

setup_uv() {
  command -v uv >/dev/null 2>&1 || { skip "uv not installed"; return 0; }
  info "Configuring uv (~/.config/uv/uv.toml)"
  local f="$HOME/.config/uv/uv.toml"
  mkdir -p "$(dirname "$f")"
  backup_file "$f"
  if [[ -f $f ]] && grep -qE '^[[:space:]]*index-url[[:space:]]*=' "$f"; then
    sed_inplace -E "s|^[[:space:]]*index-url[[:space:]]*=.*|index-url = \"$PYPI_URL\"|" "$f"
  else
    [[ -f $f ]] || : > "$f"
    printf 'index-url = "%s"\n' "$PYPI_URL" >> "$f"
  fi
  ok "wrote index-url to $f"
}

setup_cargo() {
  command -v cargo >/dev/null 2>&1 || { skip "cargo not installed"; return 0; }
  info "Configuring cargo (~/.cargo/config.toml)"
  local f="$HOME/.cargo/config.toml"
  backup_file "$f"
  upsert_block "$f" "$(cat <<EOF
[source.crates-io]
replace-with = "hf-mirror"

[source.hf-mirror]
registry = "sparse+${CARGO_URL}"
EOF
)"
  ok "wrote [source.hf-mirror] block to $f"
}

setup_go() {
  command -v go >/dev/null 2>&1 || { skip "go not installed"; return 0; }
  info "Configuring go ($GO_URL via 'go env -w')"
  # `go env -w` writes to $GOENV (~/Library/Application Support/go/env on
  # macOS, ~/.config/go/env on Linux). The `,direct` fallback lets clones of
  # private modules outside our proxy still work.
  go env -w "GOPROXY=$GO_URL,direct"
  ok "set GOPROXY=$GO_URL,direct"
}

setup_conda() {
  if ! command -v conda >/dev/null 2>&1 && ! command -v mamba >/dev/null 2>&1; then
    skip "conda/mamba not installed"
    return 0
  fi
  info "Configuring conda/mamba (~/.condarc)"
  local f="$HOME/.condarc"
  backup_file "$f"
  upsert_block "$f" "$(cat <<EOF
channel_alias: ${CONDA_URL}
default_channels:
  - ${CONDA_URL%/}/conda-forge
channels:
  - conda-forge
EOF
)"
  ok "wrote channel_alias block to $f"
}

main() {
  printf '%sHuggingFace internal registry proxy setup%s\n' "$C_BOLD" "$C_RESET"
  printf '%snpm   -> %s%s\n' "$C_DIM" "$NPM_URL" "$C_RESET"
  printf '%spypi  -> %s%s\n' "$C_DIM" "$PYPI_URL" "$C_RESET"
  printf '%scargo -> %s%s\n' "$C_DIM" "$CARGO_URL" "$C_RESET"
  printf '%sconda -> %s%s\n' "$C_DIM" "$CONDA_URL" "$C_RESET"
  printf '%sgo    -> %s%s\n' "$C_DIM" "$GO_URL" "$C_RESET"
  echo

  check_vpn
  echo
  setup_npm
  setup_yarn_classic
  setup_pip
  setup_uv
  setup_cargo
  setup_conda
  setup_go
  echo
  ok "Done. New shells will pick up env-based tooling; re-run any open shells if needed."
  printf '%sIf you need a package newer than 3 days, ping #infra.%s\n' "$C_DIM" "$C_RESET"
}

main "$@"
