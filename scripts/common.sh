#!/usr/bin/env bash

# This file is centrally managed by the altitude-travel/github-policies
# repository and will be overwritten on every policy sync. Do not edit it
# here — propose changes in github-policies instead.

# @name common
# @brief Helpers shared by the organisation's format and lint scripts.

set -euo pipefail

# Prints a message with the ERROR prefix to standard error.
#
# @arg $1 string The error message.
#
# @stderr The formatted [ERROR] line.
#
# @exitcode 0 Always.
function print_error {
  printf "[ERROR]: %s\n" "$1" >&2
}

# Prints a message with the INFO prefix to standard output.
#
# @arg $1 string The information message.
#
# @stdout The formatted [INFO] line.
#
# @exitcode 0 Always.
function print_information {
  printf "[INFO]: %s\n" "$1" >&1
}

# Checks whether a command is available on the system PATH.
#
# @arg $1 string The command name.
#
# @exitcode 0 If the command is available.
# @exitcode 1 Otherwise.
function command_exists {
  command -v "$1" &>/dev/null
}

# Prints the state of a shell option.
#
# @arg $1 string The shell option name (for example dotglob or nullglob).
#
# @example
#   state="$(shopt_state dotglob)"
#
# @stdout The state of the option: "on" or "off".
#
# @exitcode 0 Always.
function shopt_state {
  if shopt -q "$1" 2>/dev/null; then
    printf "on"
    return 0
  fi

  printf "off"
  return 0
}

# Enables or disables a shell option.
#
# @arg $1 string The shell option name (for example dotglob or nullglob).
# @arg $2 string The state to set: "on" or "off".
#
# @example
#   shopt_state_toggle dotglob "on"
#
# @stdout Nothing on success.
#
# @stderr An error message if the option name is not a shell option.
# @exitcode 0 If the option was set to the requested state.
# @exitcode 1 If the name is not a shell option.
function shopt_state_toggle {
  local option="$1"
  local state="$2"

  case "$state" in
  on)
    if shopt -s "$option" 2>/dev/null; then
      return 0
    fi
    ;;
  off)
    if shopt -u "$option" 2>/dev/null; then
      return 0
    fi
    ;;
  *)
    printf "[ERROR]: Invalid shell option state: %s\n" "$state" >&2
    return 1
    ;;
  esac

  printf "[ERROR]: Not a shell option: %s\n" "$option" >&2
  return 1
}

# Lists every .sh file below the given base directory that git does not
# ignore.
#
# @description Untracked but not-ignored files are included so files can be
# formatted before their first commit; ignored locations (node_modules, dist,
# vendor) are excluded. When the ignore check itself cannot answer (paths
# inside submodules, beyond symlinks, or outside a repository) the file is
# not ours to format: it is dropped with an [ERROR] line rather than
# silently included. Globstar and nullglob are enabled only for the walk
# and restored to the caller's state afterwards.
#
# @arg $1 string The directory to search from (for example ROOT_DIRECTORY).
#
# @stdout One .sh path per line, relative as given.
# @stderr An [ERROR] line per ignored or unresolvable file.
#
# @exitcode 0 Always.
function list_shell_scripts {
  local base_directory="$1"
  local script
  local files=()
  local globstar_was
  local nullglob_was

  globstar_was="$(shopt_state globstar)"
  nullglob_was="$(shopt_state nullglob)"

  shopt_state_toggle globstar "on"
  shopt_state_toggle nullglob "on"

  for script in "$base_directory"/**/*.sh; do
    [ -f "$script" ] || continue

    local resolved
    resolved="$(realpath "$script")"

    local ignore_status=0

    git check-ignore -q "$resolved" 2>/dev/null || ignore_status="$?"

    if [ "$ignore_status" -eq 0 ]; then
      continue
    fi

    if [ "$ignore_status" -gt 1 ]; then
      print_error "Cannot determine the gitignore status, skipping: $script"
      continue
    fi

    files+=("$script")
  done

  shopt_state_toggle globstar "$globstar_was"
  shopt_state_toggle nullglob "$nullglob_was"

  if [ "${#files[@]}" -eq 0 ]; then
    return 0
  fi

  printf '%s\n' "${files[@]}"
}
