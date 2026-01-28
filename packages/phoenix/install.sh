# phoenix
# Phoenix Framework with Ash Framework for Elixir

dependencies() {
  echo "elixir"
}

# Linux dependencies for Phoenix (inotify for live reload)
install_linux() {
  install_dep inotify-tools
}

# macOS uses fsevents natively, no extra deps needed
# install_macos()

post_install() {
  source <(mise activate bash)
  
  # Install Phoenix project generator
  mix local.hex --force
  mix archive.install hex phx_new --force
  
  # Install Ash installer for Ash Framework project generation
  mix archive.install hex igniter_new --force
}
