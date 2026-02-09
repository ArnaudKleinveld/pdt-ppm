# packages/pim/tests/config_list.bats
# Tests for `pim config list`

setup() {
  load './pim'
}

@test "config list outputs key=value lines" {
  run "$PIM_CMD" config list
  [ "$status" -eq 0 ]
  # Every non-empty line should be key=value format
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == *"="* ]]
  done <<< "$output"
}

@test "config list includes iso.iso_dir" {
  run "$PIM_CMD" config list
  [ "$status" -eq 0 ]
  [[ "$output" == *"iso.iso_dir="* ]]
}

@test "config list includes ventoy keys" {
  run "$PIM_CMD" config list
  [ "$status" -eq 0 ]
  [[ "$output" == *"ventoy.version="* ]]
  [[ "$output" == *"ventoy.dir="* ]]
  [[ "$output" == *"ventoy.file="* ]]
  [[ "$output" == *"ventoy.checksum="* ]]
}
