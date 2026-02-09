# packages/pim/tests/iso_verify.bats
# Tests for `pim iso verify`
# Requires the host-architecture ISO to be downloaded in $XDG_CACHE_HOME/pim/isos/

setup() {
  load './pim'
}

# --- Single ISO verify ---

@test "iso verify succeeds for host-architecture ISO" {
  run "$PIM_CMD" iso verify "debian-13.3.0-${HOST_ARCH}-netinst"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "iso verify fails for an unknown ISO key" {
  run "$PIM_CMD" iso verify nonexistent
  [ "$status" -eq 0 ]
  [[ "$output" == *"not found"* ]]
}

# --- Verify all ---

@test "iso verify --all reports results for downloaded ISOs" {
  run "$PIM_CMD" iso verify --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"debian-13.3.0"* ]]
  [[ "$output" == *"Summary:"* ]]
}

@test "iso verify --all shows pass count" {
  run "$PIM_CMD" iso verify --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]
}
