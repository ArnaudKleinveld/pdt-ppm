# packages/pim/tests/pim.bash
# Shared setup for all pim BATS tests
#
# Provides:
#   PIM_CMD       - path to the pim binary under test
#   PIM_PKG       - path to the pim package root
#   Sets XDG_CONFIG_HOME to the package's config dir
#   Uses real XDG_CACHE_HOME and XDG_DATA_HOME
#   Sets RUBYLIB so pim can find its libraries

# Resolve paths relative to the pim package
PIM_PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIM_CMD="${PIM_PKG}/home/.local/bin/pim"

# Use the package's own config (not the stowed symlinks)
export XDG_CONFIG_HOME="${PIM_PKG}/home/.config"

# Use real cache and data dirs (system defaults or user's environment)
# XDG_CACHE_HOME  -> defaults to ~/.cache       (ISO downloads)
# XDG_DATA_HOME   -> defaults to ~/.local/share  (images + registry)

# Set RUBYLIB so `require 'pim/iso'` etc. resolve from the package
export RUBYLIB="${PIM_PKG}/home/.local/lib/ruby${RUBYLIB:+:$RUBYLIB}"

# Detect host architecture for architecture-dependent tests
case "$(uname -m)" in
  arm64|aarch64) HOST_ARCH="arm64" ;;
  x86_64|amd64)  HOST_ARCH="amd64" ;;
  *)             HOST_ARCH="$(uname -m)" ;;
esac
