# pim - Product Image Manager

# dependencies() {
#   echo "ruby"
#   # echo "ruby podman utm"
# }

install_linux() {
  install_dep xz-utils fdisk parted dosfstools expect exfat-fuse exfat-utils
}

install_macos() {
  install_dep qemu socat
}

post_install() {
  source <(mise activate bash)
  install_gem webrick thor net-ssh net-scp
}

xyzlm() {

  # Download and extract Ventoy (config from pim.yml)
  local config_file="$XDG_CONFIG_HOME/pim/pim.yml"
  local cache_dir="$XDG_CACHE_HOME/pim/ventoy"

  # Parse ventoy config from YAML using Ruby (already installed as dependency)
  local ventoy_version ventoy_dir ventoy_file ventoy_checksum
  eval "$(ruby -ryaml -e '
    config = YAML.load_file(ARGV[0]) rescue {}
    v = config.dig("ventoy") || {}
    puts "ventoy_version=#{v["version"]}"
    puts "ventoy_dir=#{v["dir"]}"
    puts "ventoy_file=#{v["file"]}"
    puts "ventoy_checksum=#{v["checksum"]&.sub("sha256:", "")}"
  ' "$config_file")"

  if [[ -z "$ventoy_version" ]]; then
    echo "Warning: No ventoy config in $config_file, skipping Ventoy setup"
    return 0
  fi

  mkdir -p "$cache_dir"

  if [[ ! -d "$cache_dir/$ventoy_dir" ]]; then
    echo "Downloading Ventoy $ventoy_version..."
    curl -L "https://sourceforge.net/projects/ventoy/files/$ventoy_version/$ventoy_file/download" \
      -o "$cache_dir/$ventoy_file"

    echo "Verifying checksum..."
    echo "$ventoy_checksum  $cache_dir/$ventoy_file" | sha256sum -c -

    echo "Extracting..."
    tar -xzf "$cache_dir/$ventoy_file" -C "$cache_dir"
    rm "$cache_dir/$ventoy_file"
  fi

  # Create mount point directory
  mkdir -p "$cache_dir/mnt"
}
