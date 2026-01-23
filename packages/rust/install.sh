# rust

dependencies() {
  echo "mise"
}

post_install() {
  source <(mise activate bash)
  mise install rust

  source <(mise activate bash)
  rustup component add rust-analyzer
}
