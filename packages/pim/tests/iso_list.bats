# packages/pim/tests/iso_list.bats
# Tests for `pim iso list` and `pim iso ls`

setup() {
  load './pim'
}

@test "iso list shows catalog entries" {
  run "$PIM_CMD" iso list
  [ "$status" -eq 0 ]
  [[ "$output" == *"debian-13.3.0-amd64-netinst"* ]]
  [[ "$output" == *"debian-13.3.0-arm64-netinst"* ]]
}

@test "iso ls is an alias for list" {
  run "$PIM_CMD" iso ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"debian-13.3.0"* ]]
}

@test "iso list --long shows detailed format" {
  run "$PIM_CMD" iso list --long
  [ "$status" -eq 0 ]
  [[ "$output" == *"debian-13.3.0-amd64-netinst"* ]]
  [[ "$output" == *"debian-13.3.0-arm64-netinst"* ]]
}

@test "iso list --long includes total line" {
  run "$PIM_CMD" iso list --long
  [ "$status" -eq 0 ]
  [[ "$output" == *"Total:"* ]]
}
