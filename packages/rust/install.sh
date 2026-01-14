# rust

dependencies() {
  echo "mise"
}

post_install() {
  source <(mise activate zsh)
  mise install rust

  rustup component add rust-analyzer
}
