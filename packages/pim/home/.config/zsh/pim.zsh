# pim.zsh
# NOTE: These helper functions are macOS-specific (HVF accel, Homebrew
# firmware paths, vmnet-bridged networking). Cross-platform support
# belongs in PIM's Ruby code (see ADR-001 smart architecture routing).

# XDG runtime dir for sockets (macOS doesn't set XDG_RUNTIME_DIR)
export PIM_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/pim"
export PIM_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pim"

# Boot a PIM image with QMP + guest agent sockets
# Usage: pim-run [image-name] [--bridged] [--console]
pim-run() {
  local image_name=""
  local net_mode="user"
  local console=false

  # Parse args
  for arg in "$@"; do
    case "$arg" in
      --bridged) net_mode="bridged" ;;
      --console) console=true ;;
      -*) echo "Unknown flag: $arg"; return 1 ;;
      *) image_name="$arg" ;;
    esac
  done

  image_name="${image_name:-default-arm64-20260209-151408}"
  local image_dir="$PIM_DATA_DIR/images"
  local run_dir="$PIM_RUNTIME_DIR"

  mkdir -p "$run_dir"

  local qmp_sock="$run_dir/${image_name}.qmp"
  local ga_sock="$run_dir/${image_name}.ga"
  local pid_file="$run_dir/${image_name}.pid"
  local serial_sock="$run_dir/${image_name}.serial"

  # Clean up stale sockets and pidfile (sudo needed since QEMU runs as root)
  sudo rm -f "$qmp_sock" "$ga_sock" "$serial_sock" "$pid_file"

  # Network config
  local net_args
  if [[ "$net_mode" == "bridged" ]]; then
    net_args=(
      -netdev vmnet-bridged,id=net0,ifname=en0
      -device virtio-net-pci,netdev=net0
    )
  else
    net_args=(
      -netdev user,id=net0,hostfwd=tcp::2222-:22
      -device virtio-net-pci,netdev=net0
    )
  fi

  # Display/console config
  local display_args
  if $console; then
    display_args=(-nographic)
  else
    display_args=(
      -display none
      -serial unix:"$serial_sock",server=on,wait=off
    )
  fi

  echo "Starting VM: $image_name"
  echo "  Mode:         $(if $console; then echo 'console (foreground)'; else echo 'headless (background)'; fi)"
  echo "  Network:      $net_mode"
  echo "  QMP socket:   $qmp_sock"
  echo "  Guest agent:  $ga_sock"
  echo "  PID file:     $pid_file"
  $console || echo "  Serial:       $serial_sock (use pim-console $image_name to attach)"

  local qemu_cmd=(
    sudo qemu-system-aarch64
    -machine virt,accel=hvf,highmem=on -cpu host
    -smp 2 -m 2048
    "${display_args[@]}"
    -drive if=pflash,format=raw,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd,readonly=on
    -drive if=pflash,format=raw,file="${image_dir}/${image_name}-efivars.fd"
    -drive file="${image_dir}/${image_name}.qcow2",format=qcow2,if=virtio
    "${net_args[@]}"
    -qmp unix:"$qmp_sock",server=on,wait=off
    -chardev socket,path="$ga_sock",server=on,wait=off,id=qga0
    -device virtio-serial
    -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0
    -pidfile "$pid_file"
  )

  if $console; then
    "${qemu_cmd[@]}"
  else
    nohup "${qemu_cmd[@]}" > "$run_dir/${image_name}.log" 2>&1 &
    # Wait briefly for QEMU to start and write pidfile
    sleep 2
    if [[ -f "$pid_file" ]]; then
      echo "VM started (PID: $(sudo cat "$pid_file"))"
    else
      echo "Warning: VM may have failed to start. Check $run_dir/${image_name}.log"
    fi
  fi
}

# Attach to a running VM's serial console
# Usage: pim-console <image-name>
# Detach with Ctrl-O (socat escape)
pim-console() {
  local image_name="${1:?Usage: pim-console <image-name>}"
  local serial_sock="$PIM_RUNTIME_DIR/${image_name}.serial"

  if ! sudo test -S "$serial_sock"; then
    echo "No serial socket found for $image_name (was it started headless?)"
    return 1
  fi

  echo "Attaching to $image_name serial console (Ctrl-] to detach)..."
  sudo socat -,raw,echo=0,escape=0x1d UNIX-CONNECT:"$serial_sock"
}

# Query QMP - sends a command and returns JSON
# Usage: pim-qmp <image-name> '{"execute":"query-status"}'
pim-qmp() {
  local image_name="${1:?Usage: pim-qmp <image-name> <json-command>}"
  local cmd="${2:?Provide a QMP JSON command}"
  local qmp_sock="$PIM_RUNTIME_DIR/${image_name}.qmp"

  # QMP requires capabilities negotiation first
  (echo '{"execute":"qmp_capabilities"}'; sleep 0.2; echo "$cmd"; sleep 1) | sudo socat - UNIX-CONNECT:"$qmp_sock" 2>/dev/null | tail -1
}

# Query guest agent
# Usage: pim-ga <image-name> '{"execute":"guest-get-host-name"}'
pim-ga() {
  local image_name="${1:?Usage: pim-ga <image-name> <json-command>}"
  local cmd="${2:?Provide a guest-agent JSON command}"
  local ga_sock="$PIM_RUNTIME_DIR/${image_name}.ga"

  (echo "$cmd"; sleep 1) | sudo socat - UNIX-CONNECT:"$ga_sock" 2>/dev/null | head -1
}

# Convenience: list network interfaces in guest
pim-ip() {
  local image_name="${1:?Usage: pim-ip <image-name>}"
  pim-ga "$image_name" '{"execute":"guest-network-get-interfaces"}'
}

# Convenience: get guest OS info
pim-os() {
  local image_name="${1:?Usage: pim-os <image-name>}"
  pim-ga "$image_name" '{"execute":"guest-get-osinfo"}'
}

# Convenience: VM status via QMP
pim-status() {
  local image_name="${1:?Usage: pim-status <image-name>}"
  pim-qmp "$image_name" '{"execute":"query-status"}'
}

# List running PIM VMs
pim-ps() {
  local run_dir="$PIM_RUNTIME_DIR"
  if [[ ! -d "$run_dir" ]]; then
    echo "No running VMs"
    return
  fi

  printf "%-30s %-8s %-20s %-20s\n" "NAME" "PID" "QMP" "GUEST-AGENT"
  for pid_file in "$run_dir"/*.pid(N); do
    local name="$(basename "$pid_file" .pid)"
    local pid="$(sudo cat "$pid_file" 2>/dev/null)"
    local qmp="[$(test -S "$run_dir/${name}.qmp" && echo "ok" || echo "--")]"
    local ga="[$(test -S "$run_dir/${name}.ga" && echo "ok" || echo "--")]"

    # Check if process is still running (sudo needed, QEMU runs as root)
    if sudo kill -0 "$pid" 2>/dev/null; then
      printf "%-30s %-8s %-20s %-20s\n" "$name" "$pid" "$qmp" "$ga"
    else
      # Stale pid file
      printf "%-30s %-8s %-20s %-20s\n" "$name" "dead" "--" "--"
    fi
  done
}

# Graceful shutdown via guest agent, fallback to QMP quit
pim-stop() {
  local image_name="${1:?Usage: pim-stop <image-name>}"

  echo "Requesting graceful shutdown of $image_name..."
  # Try guest agent shutdown first
  pim-ga "$image_name" '{"execute":"guest-shutdown"}' 2>/dev/null

  # Wait a few seconds, then force via QMP if still running
  local pid_file="$PIM_RUNTIME_DIR/${image_name}.pid"
  local pid="$(sudo cat "$pid_file" 2>/dev/null)"
  local i=0
  while sudo kill -0 "$pid" 2>/dev/null && (( i < 15 )); do
    sleep 1
    ((i++))
  done

  if sudo kill -0 "$pid" 2>/dev/null; then
    echo "Guest agent shutdown timed out, sending QMP quit..."
    pim-qmp "$image_name" '{"execute":"quit"}'
  fi

  # Cleanup
  sudo rm -f "$PIM_RUNTIME_DIR/${image_name}".{qmp,ga,pid,serial,log}
  echo "$image_name stopped."
}
