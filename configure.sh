#!/bin/bash

set -eu

SRCDIR="$(dirname "$0")"
DEFAULT_BUILD_NAME="proton-localbuild" # If no --build-name specified

# Output helpers
COLOR_ERR=""
COLOR_STAT=""
COLOR_INFO=""
COLOR_CMD=""
COLOR_CLEAR=""
if [[ $(tput colors 2>/dev/null || echo 0) -gt 0 ]]; then
  COLOR_ERR=$'\e[31;1m'
  COLOR_STAT=$'\e[32;1m'
  COLOR_INFO=$'\e[30;1m'
  COLOR_CMD=$'\e[93;1m'
  COLOR_CLEAR=$'\e[0m'
fi

sh_quote() { 
        local quoted
        quoted="$(printf '%q ' "$@")"; [[ $# -eq 0 ]] || echo "${quoted:0:-1}"; 
}
err()      { echo >&2 "${COLOR_ERR}!!${COLOR_CLEAR} $*"; }
stat()     { echo >&2 "${COLOR_STAT}::${COLOR_CLEAR} $*"; }
info()     { echo >&2 "${COLOR_INFO}::${COLOR_CLEAR} $*"; }
showcmd()  { echo >&2 "+ ${COLOR_CMD}$(sh_quote "$@")${COLOR_CLEAR}"; }
die()      { err "$@"; exit 1; }
finish()   { stat "$@"; exit 0; }
cmd()      { showcmd "$@"; "$@"; }

#
# Configure
#

THIS_COMMAND="$0 $*" # For printing, not evaling
MAKEFILE="./Makefile"

function check_steamrt_image() {
  local type="$1"
  local name="$2"

  # nil nil -> no container
  [[ -n $type || -n $name ]] || return 0;

  # Otherwise both needed
  [[ -n $type && -n $name ]] || die "Steam Runtime SDK option must be of form type:image"

  # Type known?
  [[ $type = docker ]] || die "Only supported Steam Runtime type is currently docker"

  # Name must be alphanumericish for dumping into makefile and sanity.
  [[ $name =~ ^[a-zA-Z0-9_.-]+$ ]] || die "Runtime image name should be alphanumeric ($name)"
}

# This is not rigorous.  Do not use this for untrusted input.  Do not.  If you need a version of
# this for untrusted input, rethink the path that got you here.
function escape_for_make() {
  local escape="$1"
  escape="${escape//\\/\\\\}" #  '\' -> '\\'
  escape="${escape//#/\\#}"   #  '#' -> '\#'
  escape="${escape//\$/\$\$}" #  '$' -> '$$'
  escape="${escape// /\\ }"   #  ' ' -> '\ '
  echo "$escape"
}

function configure() {
  local steamrt64_type="${1%:*}"
  local steamrt64_name="${1#*:}"
  local steamrt32_type="${2%:*}"
  local steamrt32_name="${2#*:}"
  local steamrt_path="${3}"

  check_steamrt_image "$steamrt64_type" "$steamrt64_name"
  check_steamrt_image "$steamrt32_type" "$steamrt32_name"

  local srcdir
  srcdir="$(dirname "$0")"

  # Build name
  local build_name="$arg_build_name"
  if [[ -n $build_name ]]; then
    info "Configuring with build name: $build_name"
  else
    build_name="$DEFAULT_BUILD_NAME"
    info "No build name specified, using default: $build_name"
  fi

  ## Write out config
  # Don't die after this point or we'll have rather unhelpfully deleted the Makefile
  [[ ! -e "$MAKEFILE" ]] || rm "$MAKEFILE"

  {
    # Config
    echo "# Generated by: $THIS_COMMAND"
    echo ""
    echo "SRCDIR     := $(escape_for_make "$srcdir")"
    echo "BUILD_NAME := $(escape_for_make "$build_name")"

    # ffmpeg?
    if [[ -n $arg_ffmpeg ]]; then
      echo "WITH_FFMPEG := 1"
    fi

    # SteamRT
    echo "STEAMRT64_MODE  := $(escape_for_make "$steamrt64_type")"
    echo "STEAMRT64_IMAGE := $(escape_for_make "$steamrt64_name")"
    echo "STEAMRT32_MODE  := $(escape_for_make "$steamrt32_type")"
    echo "STEAMRT32_IMAGE := $(escape_for_make "$steamrt32_name")"
    echo "STEAMRT_PATH    := $(escape_for_make "$steamrt_path")"

    if [[ -n "$arg_crosscc_prefix" ]]; then
      echo "DXVK_CROSSCC_PREFIX := $(escape_for_make "$arg_crosscc_prefix")," #comma is not a typo
    fi

    # Include base
    echo ""
    echo "include \$(SRCDIR)/build/makefile_base.mak"
  } >> "$MAKEFILE"

  stat "Created $MAKEFILE, now run make to build."
  stat "  See README.md for make targets and instructions"
}

#
# Parse arguments
#

arg_steamrt32=""
arg_steamrt64=""
arg_steamrt=""
arg_no_steamrt=""
arg_ffmpeg=""
arg_build_name=""
arg_crosscc_prefix=""
arg_help=""
invalid_args=""
function parse_args() {
  local arg;
  local val;
  local val_used;
  local val_passed;
  while [[ $# -gt 0 ]]; do
    arg="$1"
    val=''
    val_used=''
    val_passed=''
    if [[ -z $arg ]]; then # Sanity
      err "Unexpected empty argument"
      return 1
    elif [[ ${arg:0:2} != '--' ]]; then
      err "Unexpected positional argument ($1)"
      return 1
    fi

    # Looks like an argument does it have a --foo=bar value?
    if [[ ${arg%=*} != "$arg" ]]; then
      val="${arg#*=}"
      arg="${arg%=*}"
      val_passed=1
    else
      # Otherwise for args that want a value, assume "--arg val" form
      val="${2:-}"
    fi

    # The args
    if [[ $arg = --help || $arg = --usage ]]; then
      arg_help=1
    elif [[ $arg = --build-name ]]; then
      arg_build_name="$val"
      val_used=1
    elif [[ $arg = --dxvk-crosscc-prefix ]]; then
      arg_crosscc_prefix="$val"
      val_used=1
    elif [[ $arg = --with-ffmpeg ]]; then
      arg_ffmpeg=1
    elif [[ $arg = --steam-runtime32 ]]; then
      val_used=1
      arg_steamrt32="$val"
    elif [[ $arg = --steam-runtime64 ]]; then
      val_used=1
      arg_steamrt64="$val"
    elif [[ $arg = --steam-runtime ]]; then
      val_used=1
      arg_steamrt="$val"
    elif [[ $arg = --no-steam-runtime ]]; then
      arg_no_steamrt=1
    else
      err "Unrecognized option $arg"
      return 1
    fi

    # Check if this arg used the value and shouldn't have or vice-versa
    if [[ -n $val_used && -z $val_passed ]]; then
      # "--arg val" form, used $2 as the value.

      # Don't allow this if it looked like "--arg --val"
      if [[ ${val#--} != "$val" ]]; then
        err "Ambiguous format for argument with value \"$arg $val\""
        err "  (use $arg=$val or $arg='' $val)"
        return 1
      fi

      # Error if this was the last positional argument but expected $val
      if [[ $# -le 1 ]]; then
        err "$arg takes a parameter, but none given"
        return 1
      fi

      shift # consume val
    elif [[ -z $val_used && -n $val_passed ]]; then
      # Didn't use a value, but passed in --arg=val form
      err "$arg does not take a parameter"
      return 1
    fi

    shift # consume arg
  done
}

usage() {
  "$1" "Usage: $0 { --no-steam-runtime | --steam-runtime32=<image> --steam-runtime64=<image> --steam-runtime=<path> }"
  "$1" "  Generate a Makefile for building Proton.  May be run from another directory to create"
  "$1" "  out-of-tree build directories (e.g. mkdir mybuild && cd mybuild && ../configure.sh)"
  "$1" ""
  "$1" "  Options"
  "$1" "    --help / --usage     Show this help text and exit"
  "$1" ""
  "$1" "    --build-name=<name>  Set the name of the build that displays when used in Steam"
  "$1" ""
  "$1" "    --with-ffmpeg        Build ffmpeg for WMA audio support"
  "$1" ""
  "$1" "    --dxvk-crosscc-prefix='<prefix>' Quoted and comma-separated list of arguments to prefix before"
  "$1" "                                     the cross-compiler that builds DXVK. E.g:"
  "$1" "                                     --dxvk-crosscc-prefix=\"schroot\",\"-c\",\"some_chroot\",\"--\""
  "$1" ""
  "$1" "  Steam Runtime"
  "$1" "    Proton builds that are to be installed & run under the steam client must be built with"
  "$1" "    the Steam Runtime SDK to ensure compatibility.  See README.md for more information."
  "$1" ""
  "$1" "    --steam-runtime64=docker:<image>  Automatically invoke the Steam Runtime SDK in <image>"
  "$1" "                                      for build steps that must be run in an SDK"
  "$1" "                                      environment.  See README.md for instructions to"
  "$1" "                                      create this image."
  "$1" ""
  "$1" "    --steam-runtime32=docker:<image>  The 32-bit docker image to use for steps that require"
  "$1" "                                      a 32-bit environment.  See --steam-runtime64."
  "$1" ""
  "$1" "    --steam-runtime=<path>            Path to the runtime built for the host (i.e. the output"
  "$1" "                                      directory given to steam-runtime/build-runtime.py). Should"
  "$1" "                                      contain run.sh."
  "$1" ""
  "$1" "    --no-steam-runtime  Do not automatically invoke any runtime SDK as part of the build."
  "$1" "                        Build steps may still be manually run in a runtime environment."
  exit 1;
}

[[ $# -gt 0 ]] || usage info
parse_args "$@" || usage err
[[ -z $arg_help ]] || usage info

# Sanity check arguments
if [[ -n $arg_no_steamrt && (-n $arg_steamrt32 || -n $arg_steamrt64 || -n $arg_steamrt) ]]; then
    die "Cannot specify a Steam Runtime SDK as well as --no-steam-runtime"
elif [[ -z $arg_no_steamrt && ( -z $arg_steamrt32 || -z $arg_steamrt64 || -z $arg_steamrt ) ]]; then
    die "Must specify either --no-steam-runtime or all of --steam-runtime32, --steam-runtime64, and --steam-runtime"
fi

configure "$arg_steamrt64" "$arg_steamrt32" "$arg_steamrt"
