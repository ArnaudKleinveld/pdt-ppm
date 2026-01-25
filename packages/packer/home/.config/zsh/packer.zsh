# packer


# packer specific env vars
export PACKER_CONFIG_DIR="$XDG_CONFIG_HOME/packer"
export PACKER_CACHE_DIR="$XDG_CACHE_HOME/packer"
export PACKER_PLUGIN_PATH="$XDG_CACHE_HOME/packer/plugins"


# PIM Packer configuration
export PIM_PACKER_CONFIG_HOME="$XDG_CONFIG_HOME/pim/templates/packer"

# Initialize all packer templates in pim
pim-packer-init() {
  if [[ ! -d "$PIM_PACKER_CONFIG_HOME" ]]; then
    echo "Template directory not found: $PIM_PACKER_CONFIG_HOME"
    return 1
  fi
  
  pushd "$PIM_PACKER_CONFIG_HOME" > /dev/null
  
  local count=0
  for hcl in *.pkr.hcl(N); do
    if [[ -f "$hcl" ]]; then
      echo "Initializing: $hcl"
      packer init "$hcl"
      ((count++))
    fi
  done
  
  popd > /dev/null
  
  if ((count == 0)); then
    echo "No .pkr.hcl files found"
  else
    echo "\nInitialized $count template(s)"
  fi
}
