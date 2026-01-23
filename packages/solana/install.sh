# solana

dependencies() {
  echo "rust node"
}

post_install() {
  source <(mise activate bash)
  curl --proto '=https' --tlsv1.2 -sSfL https://solana-install.solana.workers.dev | bash
}

