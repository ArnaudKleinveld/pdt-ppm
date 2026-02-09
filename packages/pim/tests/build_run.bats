# packages/pim/tests/build_run.bats
# Tests for `pim build run`
# Requires ISOs to be downloaded in $XDG_CACHE_HOME/pim/isos/

setup() {
  load './pim'
}

@test "build run --dry-run shows build plan" {
  run "$PIM_CMD" build run default --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run:"* ]]
  [[ "$output" == *"Configuration:"* ]]
  [[ "$output" == *"Profile:"* ]]
  [[ "$output" == *"Build steps:"* ]]
}

@test "build run --dry-run shows ISO info" {
  run "$PIM_CMD" build run default --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"ISO:"* ]]
  [[ "$output" == *"Key:"* ]]
}

@test "build run --dry-run shows scripts info" {
  run "$PIM_CMD" build run default --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Scripts"* ]]
}

@test "build run --dry-run shows cache status" {
  run "$PIM_CMD" build run default --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cache:"* ]]
  [[ "$output" == *"Key:"* ]]
}

@test "build run --dry-run resolves ISO for host architecture" {
  run "$PIM_CMD" build run default --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Exists:"*"yes"* ]]
}
