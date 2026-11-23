#!/usr/bin/env bash
set -euo pipefail

use_retroarch=false
for argument in "$@"; do
  if [[ "$argument" == --frontend:retroarch ]]; then use_retroarch=true; fi
done

if ! "$use_retroarch"; then
  project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  exec "$project_root/build/mono-retro-player" "$@"
fi

core=
rom=
save_dir=
screenshot_dir=
for argument in "$@"; do
  case "$argument" in
    --frontend:retroarch) ;;
    --core:*) core=${argument#--core:} ;;
    --rom:*) rom=${argument#--rom:} ;;
    --save-dir:*) save_dir=${argument#--save-dir:} ;;
    --screenstate-dir:*) screenshot_dir=${argument#--screenstate-dir:} ;;
    *) printf 'Unsupported RetroArch launch argument: %s\n' "$argument" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$core" || ! -f "$rom" || -z "$save_dir" || -z "$screenshot_dir" ]]; then
  printf 'RetroArch requires an installed core, ROM, save directory and screenshot directory.\n' >&2
  exit 2
fi

config_string() {
  # Quote paths for RetroArch configuration, without evaluating their contents.
  local value=$1
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    printf 'RetroArch paths cannot contain line breaks.\n' >&2
    exit 2
  fi
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

mkdir -p -- "$save_dir/states" "$screenshot_dir"
launch_config="$save_dir/retroarch-launch.cfg"
umask 077
{
  printf '#include '; config_string "${XDG_CONFIG_HOME:-$HOME/.config}/retroarch/retroarch.cfg"; printf '\n'
  printf 'savefile_directory = '; config_string "$save_dir"; printf '\n'
  printf 'savestate_directory = '; config_string "$save_dir/states"; printf '\n'
  printf 'screenshot_directory = '; config_string "$screenshot_dir"; printf '\n'
  printf 'sort_savefiles_enable = "false"\nsort_savefiles_by_content_enable = "false"\n'
  printf 'sort_savestates_enable = "false"\nsort_savestates_by_content_enable = "false"\n'
  printf 'config_save_on_exit = "false"\n'
} > "$launch_config"

exec retroarch --config "$launch_config" -L "$core" "$rom"
