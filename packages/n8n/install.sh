#!/bin/bash

dependencies() {
  echo ""  # No PPM dependencies - Docker handles everything
}

install_linux() {
  # Ensure Docker is installed
  if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is required but not installed."
    echo "Install Docker via: https://docs.docker.com/engine/install/"
    exit 1
  fi

  # Check for docker compose (v2 plugin or standalone)
  if ! docker compose version &>/dev/null && ! docker-compose version &>/dev/null; then
    echo "ERROR: Docker Compose is required but not installed."
    echo "Install Docker Compose via: https://docs.docker.com/compose/install/"
    exit 1
  fi
}

install_macos() {
  if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker Desktop is required but not installed."
    echo "Download from: https://www.docker.com/products/docker-desktop/"
    exit 1
  fi

  # Docker Desktop includes docker compose
  if ! docker compose version &>/dev/null; then
    echo "ERROR: Docker Compose not available. Please update Docker Desktop."
    exit 1
  fi
}

post_install() {
  local service_dir="$XDG_DATA_HOME/n8n"

  # Create data directory with proper permissions
  mkdir -p "$service_dir/data"

  # Copy env template if .env doesn't exist
  if [[ ! -f "$service_dir/.env" ]]; then
    cp "$service_dir/.env.example" "$service_dir/.env"
    echo ""
    echo "⚠️  IMPORTANT: Review and update $service_dir/.env"
    echo "   Set a secure N8N_BASIC_AUTH_PASSWORD before starting n8n"
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "n8n installation complete!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Quick Start Commands:"
  echo "  n8n-up       - Start n8n service"
  echo "  n8n-down     - Stop n8n service"
  echo "  n8n-logs     - View n8n logs"
  echo "  n8n-restart  - Restart n8n service"
  echo ""
  echo "Access n8n at: http://localhost:5678"
  echo ""
  echo "Configuration: $service_dir/.env"
  echo "Data location: $service_dir/data"
  echo ""
}

pre_remove() {
  local service_dir="$XDG_DATA_HOME/n8n"

  if [[ -f "$service_dir/docker-compose.yml" ]]; then
    echo "Stopping n8n container..."
    cd "$service_dir" || return
    docker compose down 2>/dev/null || docker-compose down 2>/dev/null || true
  fi
}

post_remove() {
  local service_dir="$XDG_DATA_HOME/n8n"

  echo ""
  echo "n8n has been removed."
  echo ""
  echo "Your workflows and data are preserved at: $service_dir/data"
  echo "To completely remove n8n data:"
  echo "  rm -rf $service_dir/data"
  echo "  rm -f $service_dir/.env"
  echo ""
}
