# rust

dependencies() {
  echo "mise"
}

post_install() {
  source <(mise activate zsh)
  mise install rust

  source <(mise activate zsh)
  rustup component add rust-analyzer
}
