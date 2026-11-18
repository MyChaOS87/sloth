function check_programs_available {
  local result=0
  local p
  for p in "$@"; do
    echo -n "check if $p is available: " 1>&2
    if ! command -v "$p" &> /dev/null; then
        echo "ERROR: not found, please install $p" 1>&2
        result=1
    else
        echo "OK!" 1>&2
    fi
  done

  return $result
}


function assert_no_overwrite {
  if [ -f "$1" ]; then
    echo "ERROR: $1 already exists, please remove it first if you want to recreate it from scratch" 1>&2
    return 1
  fi

  return 0
}

function load_sloth_env {
  local repo_root="${1:-$(pwd)}"
  local main_repo_root=""
  if ! main_repo_root="$(cd "${repo_root}" && cd "$(git rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd)"; then
    main_repo_root="${repo_root}"
  fi

  for env_file in \
    "${repo_root}/.secrets/sloth.env" \
    "${main_repo_root}/.secrets/sloth.env"; do
    if [ -f "${env_file}" ]; then
      # shellcheck disable=SC1090
      source "${env_file}"
      break
    fi
  done

  SLOTH_PRIVATE_DIR="${SLOTH_PRIVATE_DIR:-${main_repo_root}/../sloth-private}"
  PRIVATE_REPO_URL="${PRIVATE_REPO_URL:-git@github.com:MyChaOS87/sloth-private.git}"
  export SLOTH_PRIVATE_DIR PRIVATE_REPO_URL
}

function ensure_parent_dir {
  mkdir -p "$(dirname "$1")"
}