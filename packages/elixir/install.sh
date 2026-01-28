# elixir
# Elixir programming language with Erlang/OTP (BEAM VM)

dependencies() {
  echo "mise"
}

# Linux build dependencies for Erlang/OTP compilation
# These are needed because mise compiles Erlang from source on Linux
install_linux() {
  install_dep build-essential autoconf m4 libncurses5-dev libssl-dev
}

# macOS uses precompiled binaries via homebrew, no extra deps needed
install_macos() {
  # OpenSSL is recommended for Erlang builds on macOS
  install_dep openssl
}

post_install() {
  source <(mise activate bash)
  
  # Install Erlang first (required runtime for Elixir)
  mise install erlang
  
  # Install Elixir
  mise install elixir
  
  # Ensure shims are created for mix escripts
  source <(mise activate bash)
}
