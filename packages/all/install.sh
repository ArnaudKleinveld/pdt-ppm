# all

dependencies() {
  ppm list $(repo_name) | cut -d'/' -f2 | grep -v '^all$'
}

repo_name() {
  basename "$(dirname "$(dirname "$(dirname "${BASH_SOURCE[1]}")")")"
}
