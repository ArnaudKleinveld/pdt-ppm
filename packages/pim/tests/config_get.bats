# packages/pim/tests/config_get.bats
# Tests for `pim config get`

setup() {
  load './pim'
}

@test "config get ventoy.version returns expected value" {
  run "$PIM_CMD" config get ventoy.version
  [ "$status" -eq 0 ]
  [ "$output" = "v1.0.99" ]
}

@test "config get iso.iso_dir returns a path" {
  run "$PIM_CMD" config get iso.iso_dir
  [ "$status" -eq 0 ]
  [[ "$output" == *"pim/isos"* ]]
}

@test "config get unknown.key exits 1" {
  run "$PIM_CMD" config get no.such.key
  [ "$status" -eq 1 ]
}

@test "config get parent key prints nested values" {
  run "$PIM_CMD" config get ventoy
  [ "$status" -eq 0 ]
  [[ "$output" == *"ventoy.version="* ]]
  [[ "$output" == *"ventoy.dir="* ]]
}
