#!/usr/bin/env bash
# Pure-Bash leak guard: enforces private blacklist rules (from SLOTH_PRIVATE_DIR/blacklist.txt),
# forbidden .env files, and hardcoded home-directory paths across staged changes, commit messages,
# outgoing pushes, or full Git history of public sloth.
set -euo pipefail

resolve_common_dir() {
  local dir="$1"
  local common=""
  if ! common="$(git -C "${dir}" rev-parse --git-common-dir 2>/dev/null)"; then
    return 1
  fi
  if [[ "${common}" != /* ]]; then
    common="$(cd "${dir}" && cd "${common}" && pwd)"
  fi
  printf '%s\n' "${common}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_COMMON_DIR="$(resolve_common_dir "${SCRIPT_REPO_ROOT}")"
CWD_COMMON_DIR="$(resolve_common_dir "$(pwd)" || true)"

if [[ -n "${CWD_COMMON_DIR}" && "${CWD_COMMON_DIR}" == "${SCRIPT_COMMON_DIR}" ]]; then
  REPO_ROOT="$(git rev-parse --show-toplevel)"
else
  REPO_ROOT="${SCRIPT_REPO_ROOT}"
fi
MAIN_REPO_ROOT="$(cd "${SCRIPT_COMMON_DIR}/.." && pwd)"

# shellcheck source=../.check.lib.sh
source "${SCRIPT_REPO_ROOT}/.check.lib.sh"
load_sloth_env "${REPO_ROOT}"

# Normalize relative SLOTH_PRIVATE_DIR values against the main checkout root so hooks
# work consistently inside git worktrees and non-root working directories.
if [[ "${SLOTH_PRIVATE_DIR}" != /* ]]; then
  SLOTH_PRIVATE_DIR="${MAIN_REPO_ROOT}/${SLOTH_PRIVATE_DIR}"
fi
if [[ -d "${SLOTH_PRIVATE_DIR}" ]]; then
  SLOTH_PRIVATE_DIR="$(cd "${SLOTH_PRIVATE_DIR}" && pwd)"
fi
export SLOTH_PRIVATE_DIR

# Construct without literal slash-h-o-m-e so this script never triggers on itself.
HOME_TOKEN="/""home"
HOME_REGEX="(^|[^[:alnum:]_.-])${HOME_TOKEN}(/|[^[:alnum:]_-]|$)"

TMP_WORK="$(mktemp -d)"
trap 'rm -rf "${TMP_WORK}"' EXIT

LIT_PATTERNS_FILE="${TMP_WORK}/literals.txt"
RE_PATTERNS_FILE="${TMP_WORK}/regexes.txt"
VIOLATIONS_FILE="${TMP_WORK}/violations.txt"
: > "${LIT_PATTERNS_FILE}"
: > "${RE_PATTERNS_FILE}"
: > "${VIOLATIONS_FILE}"

RULE_LINES=()
RULE_KINDS=()
RULE_RAWS=()
RULE_COUNT=0
SKIPPED_MISSING=0
VIOLATION_COUNT=0
declare -A SEEN_VIOLATIONS=()

usage() {
  cat >&2 <<'EOF'
Usage: check-blacklist.sh <--staged | --commit-msg <file> | --pre-push | --all>
EOF
}

fail_closed_box() {
  local mode="$1"
  local reason="$2"
  local detail="$3"
  local fix="$4"
  local bar="=========================================================================="
  {
    printf '\n%s\n' "${bar}"
    printf '[sloth leak-guard] BLOCKED (%s) — CONFIGURATION ERROR (FAIL-CLOSED)\n' "${mode}"
    printf '%s\n' "${bar}"
    printf '  Reason : %s\n' "${reason}"
    printf '           %s\n' "${detail}"
    printf "  Why    : Public 'sloth' refuses to commit or push without verifying\n"
    printf "           against 'sloth-private/blacklist.txt'.\n"
    printf '  Fix    : %s\n' "${fix}"
    printf '%s\n\n' "${bar}"
  } >&2
  exit 2
}

trim_excerpt() {
  local text="$1"
  local max_len=140
  local cleaned
  cleaned="$(printf '%s' "${text}" | tr '\r\t' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  if (( ${#cleaned} > max_len )); then
    cleaned="${cleaned:0:max_len-3}..."
  fi
  printf '%s' "${cleaned}"
}

add_violation() {
  local category="$1"
  local location="$2"
  local rule="$3"
  local why="$4"
  local raw_excerpt="$5"
  local dedup_key="$6"

  local seen_id="${category}|${dedup_key}|${rule}"
  if [[ -n "${SEEN_VIOLATIONS[${seen_id}]:-}" ]]; then
    return 0
  fi
  SEEN_VIOLATIONS["${seen_id}"]=1

  VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
  local excerpt
  excerpt="$(trim_excerpt "${raw_excerpt}")"
  {
    printf '  [%d] %s\n' "${VIOLATION_COUNT}" "${category}"
    printf '      Location : %s\n' "${location}"
    printf '      Rule     : %s\n' "${rule}"
    printf '      Why      : %s\n' "${why}"
    printf '      Excerpt  : %s\n' "${excerpt}"
  } >> "${VIOLATIONS_FILE}"
}

load_blacklist() {
  local mode="$1"
  local allow_missing="${SLOTH_ALLOW_MISSING_BLACKLIST:-0}"
  local bl_path="${SLOTH_PRIVATE_DIR}/blacklist.txt"

  if [[ ! -f "${bl_path}" || ! -r "${bl_path}" ]]; then
    if [[ "${allow_missing}" == "1" ]]; then
      SKIPPED_MISSING=1
      return 0
    fi
    fail_closed_box \
      "${mode}" \
      "Private blacklist file not found:" \
      "${bl_path}" \
      "Ensure 'sloth-private' is checked out at SLOTH_PRIVATE_DIR (default ../sloth-private, or configure .secrets/sloth.env). For clean-room CI only: SLOTH_ALLOW_MISSING_BLACKLIST=1"
  fi

  local line_no=0
  local raw_line=""
  local stripped=""
  local expr=""
  local rc=0
  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    line_no=$((line_no + 1))
    stripped="${raw_line%$'\r'}"
    stripped="${stripped#"${stripped%%[![:space:]]*}"}"
    stripped="${stripped%"${stripped##*[![:space:]]}"}"
    [[ -z "${stripped}" || "${stripped}" == \#* ]] && continue

    if [[ "${stripped}" == regex:* ]]; then
      expr="${stripped#regex:}"
      expr="${expr#"${expr%%[![:space:]]*}"}"
      expr="${expr%"${expr##*[![:space:]]}"}"
      if [[ -z "${expr}" ]]; then
        fail_closed_box \
          "${mode}" \
          "Invalid empty 'regex:' entry in blacklist.txt:${line_no}" \
          "${bl_path}" \
          "Remove the empty regex: line or provide a valid pattern."
      fi
      rc=0
      printf '' | grep -E -i -e "${expr}" >/dev/null 2>&1 || rc=$?
      if (( rc > 1 )); then
        fail_closed_box \
          "${mode}" \
          "Invalid regex in blacklist.txt:${line_no} ('${expr}')" \
          "${bl_path}" \
          "Fix the extended regular expression in sloth-private/blacklist.txt."
      fi
      RULE_LINES+=("${line_no}")
      RULE_KINDS+=("regex")
      RULE_RAWS+=("${expr}")
      printf '%s\n' "${expr}" >> "${RE_PATTERNS_FILE}"
    else
      RULE_LINES+=("${line_no}")
      RULE_KINDS+=("literal")
      RULE_RAWS+=("${stripped}")
      printf '%s\n' "${stripped}" >> "${LIT_PATTERNS_FILE}"
    fi
  done < "${bl_path}"

  RULE_COUNT="${#RULE_RAWS[@]}"
  if (( RULE_COUNT == 0 )); then
    if [[ "${allow_missing}" == "1" ]]; then
      SKIPPED_MISSING=1
      return 0
    fi
    fail_closed_box \
      "${mode}" \
      "Private blacklist file contains 0 active rules:" \
      "${bl_path}" \
      "Add at least one private identifier rule to sloth-private/blacklist.txt (or set SLOTH_ALLOW_MISSING_BLACKLIST=1 for clean-room CI)."
  fi
}

line_matches_rule() {
  local line="$1"
  local idx="$2"
  local kind="${RULE_KINDS[${idx}]}"
  local raw="${RULE_RAWS[${idx}]}"
  if [[ "${kind}" == "regex" ]]; then
    printf '%s\n' "${line}" | grep -E -i -q -e "${raw}"
  else
    printf '%s\n' "${line}" | grep -F -i -q -- "${raw}"
  fi
}

match_blacklist_line() {
  local line="$1"
  local location="$2"
  local dedup_id="$3"
  local why="$4"
  local i
  for (( i = 0; i < RULE_COUNT; i++ )); do
    if line_matches_rule "${line}" "${i}"; then
      add_violation \
        "PRIVATE_BLACKLIST_MATCH" \
        "${location}" \
        "sloth-private/blacklist.txt:${RULE_LINES[${i}]} (${RULE_KINDS[${i}]} '${RULE_RAWS[${i}]}')" \
        "${why}" \
        "${line}" \
        "${dedup_id}"
    fi
  done
}

check_path() {
  local path="$1"
  local loc_prefix="$2"
  local check_home="$3"
  local dedup_id="$4"

  local norm="${path//\\//}"
  local base="${norm##*/}"
  local base_lower="${base,,}"

  if [[ "${base_lower}" == ".env" || "${base_lower}" == .env.* || "${base_lower}" == *.env ]]; then
    add_violation \
      "FORBIDDEN_ENV_FILE" \
      "${loc_prefix}${norm}" \
      "forbidden .env file (.env, .env.*, *.env)" \
      "Environment files (.env, .env.*, *.env) often contain local endpoints or secrets and must stay untracked." \
      "${norm}" \
      "${dedup_id}"
  fi

  if [[ "${check_home}" == "1" ]] && printf '%s\n' "${norm}" | grep -E -q -e "${HOME_REGEX}"; then
    add_violation \
      "HOME_PATH_LEAK" \
      "${loc_prefix}${norm}" \
      "forbidden ${HOME_TOKEN} path" \
      "Hardcoded ${HOME_TOKEN} path leaked in file path; use relative paths or '~user' / environment variables." \
      "${norm}" \
      "${dedup_id}"
  fi

  match_blacklist_line \
    "${norm}" \
    "${loc_prefix}${norm}" \
    "${dedup_id}" \
    "File path matches a private identifier listed in sloth-private/blacklist.txt."
}

collect_grep_file_hits() {
  local target_file="$1"
  local check_home="$2"
  local out_file="$3"
  local rc=0
  : > "${out_file}"

  if [[ "${check_home}" == "1" ]]; then
    rc=0
    grep -I -n -E -e "${HOME_REGEX}" "${target_file}" >> "${out_file}" || rc=$?
    if (( rc > 1 )); then
      printf 'grep failed scanning %s\n' "${target_file}" >&2
      exit 2
    fi
  fi
  if [[ -s "${LIT_PATTERNS_FILE}" ]]; then
    rc=0
    grep -I -n -F -i -f "${LIT_PATTERNS_FILE}" "${target_file}" >> "${out_file}" || rc=$?
    if (( rc > 1 )); then
      printf 'grep literal scan failed on %s\n' "${target_file}" >&2
      exit 2
    fi
  fi
  if [[ -s "${RE_PATTERNS_FILE}" ]]; then
    rc=0
    grep -I -n -E -i -f "${RE_PATTERNS_FILE}" "${target_file}" >> "${out_file}" || rc=$?
    if (( rc > 1 )); then
      printf 'grep regex scan failed on %s\n' "${target_file}" >&2
      exit 2
    fi
  fi
}

scan_text_file() {
  local target_file="$1"
  local loc_prefix="$2"
  local check_home="$3"
  local is_commit_msg="$4"
  local dedup_prefix="$5"

  local scan_file="${target_file}"
  if [[ "${is_commit_msg}" == "1" ]]; then
    scan_file="${TMP_WORK}/commit_msg_clean.txt"
    awk '
      /^[[:space:]]*# ------------------------ >8 ------------------------/ { exit }
      /^[[:space:]]*#/ { print ""; next }
      { print }
    ' "${target_file}" > "${scan_file}"
  fi

  local hits_file="${TMP_WORK}/file_hits.txt"
  collect_grep_file_hits "${scan_file}" "${check_home}" "${hits_file}"
  [[ ! -s "${hits_file}" ]] && return 0

  local unique_hits="${TMP_WORK}/file_hits_sorted.txt"
  sort -t: -k1,1n -u "${hits_file}" > "${unique_hits}"

  local lineno=""
  local content=""
  while IFS=: read -r lineno content; do
    [[ -z "${lineno}" ]] && continue
    local loc="${loc_prefix}:${lineno}"
    local did="${dedup_prefix}:${lineno}"

    if [[ "${check_home}" == "1" ]] && printf '%s\n' "${content}" | grep -E -q -e "${HOME_REGEX}"; then
      add_violation \
        "HOME_PATH_LEAK" \
        "${loc}" \
        "forbidden ${HOME_TOKEN} path" \
        "Hardcoded ${HOME_TOKEN} path detected; use repository-relative links or '~user' instead." \
        "${content}" \
        "${did}"
    fi
    match_blacklist_line \
      "${content}" \
      "${loc}" \
      "${did}" \
      "Line contains a private identifier from sloth-private/blacklist.txt; move to sloth-private or replace with example.com / example-dns."
  done < "${unique_hits}"
}

run_git_grep_into() {
  local out_file="$1"
  shift
  local rc=0
  git -C "${REPO_ROOT}" grep -z -I -n "$@" >> "${out_file}" || rc=$?
  if (( rc > 1 )); then
    printf 'git grep failed (exit %d)\n' "${rc}" >&2
    exit 2
  fi
}

scan_git_grep_scope() {
  local mode_kind="$1" # "cached" | "rev"
  local loc_prefix="$2"
  local check_home="$3"
  local dedup_mode="$4" # "location" | "pathline"
  shift 4
  # Remaining args: git grep scope/revs + '--' + optional paths
  local raw_gg="${TMP_WORK}/git_grep_raw.bin"
  local parsed_gg="${TMP_WORK}/git_grep_parsed.txt"
  : > "${raw_gg}"

  if [[ "${check_home}" == "1" ]]; then
    run_git_grep_into "${raw_gg}" -E -e "${HOME_REGEX}" "$@"
  fi
  if [[ -s "${LIT_PATTERNS_FILE}" ]]; then
    run_git_grep_into "${raw_gg}" -F -i -f "${LIT_PATTERNS_FILE}" "$@"
  fi
  if [[ -s "${RE_PATTERNS_FILE}" ]]; then
    run_git_grep_into "${raw_gg}" -E -i -f "${RE_PATTERNS_FILE}" "$@"
  fi

  [[ ! -s "${raw_gg}" ]] && return 0

  # git grep -z -n emits: <spec>\0<lineno>\0<content>\n
  awk -F'\0' '{ gsub(/\r/, "", $3); printf "%s\n%s\n%s\n", $1, $2, $3 }' "${raw_gg}" > "${parsed_gg}"

  local spec=""
  local lineno=""
  local content=""
  while IFS= read -r spec && IFS= read -r lineno && IFS= read -r content; do
    local rev=""
    local path=""
    local disp_loc=""
    local did=""

    if [[ "${mode_kind}" == "cached" ]]; then
      path="${spec}"
      disp_loc="${loc_prefix}${path}:${lineno}"
    else
      rev="${spec%%:*}"
      path="${spec#*:}"
      if [[ "${rev}" =~ ^[0-9a-f]{40}$ ]]; then
        rev="${rev:0:7}"
      fi
      if [[ "${rev}" == "HEAD" && "${loc_prefix}" == "HEAD " ]]; then
        disp_loc="HEAD ${path}:${lineno}"
      else
        disp_loc="commit ${rev} ${path}:${lineno}"
      fi
    fi

    if [[ "${dedup_mode}" == "pathline" ]]; then
      did="history:${path}:${lineno}"
    else
      did="${disp_loc}"
    fi

    if [[ "${check_home}" == "1" ]] && printf '%s\n' "${content}" | grep -E -q -e "${HOME_REGEX}"; then
      add_violation \
        "HOME_PATH_LEAK" \
        "${disp_loc}" \
        "forbidden ${HOME_TOKEN} path" \
        "Hardcoded ${HOME_TOKEN} path detected; use repository-relative links or '~user' instead." \
        "${content}" \
        "${did}"
    fi
    match_blacklist_line \
      "${content}" \
      "${disp_loc}" \
      "${did}" \
      "Line contains a private identifier from sloth-private/blacklist.txt; move to sloth-private or replace with example.com / example-dns."
  done < "${parsed_gg}"
}

scan_staged() {
  local -a staged_paths=()
  mapfile -d '' -t staged_paths < <(git -C "${REPO_ROOT}" diff --cached --name-only --diff-filter=ACMR -z)
  (( ${#staged_paths[@]} == 0 )) && return 0

  local p
  for p in "${staged_paths[@]}"; do
    check_path "${p}" "staged " 1 "staged:${p}"
  done

  scan_git_grep_scope "cached" "staged " 1 "location" --cached -- "${staged_paths[@]}"
}

scan_commit_msg_file() {
  local msg_file="$1"
  if [[ ! -f "${msg_file}" ]]; then
    printf 'Commit message file not found: %s\n' "${msg_file}" >&2
    exit 2
  fi
  scan_text_file "${msg_file}" "commit-msg (${msg_file##*/})" 1 1 "commit-msg"
}

scan_head_tree() {
  git -C "${REPO_ROOT}" rev-parse --verify HEAD >/dev/null 2>&1 || return 0

  local -a head_paths=()
  mapfile -d '' -t head_paths < <(git -C "${REPO_ROOT}" ls-files -z)
  local p
  for p in "${head_paths[@]}"; do
    check_path "${p}" "HEAD " 1 "HEAD:${p}"
  done

  if (( ${#head_paths[@]} > 0 )); then
    scan_git_grep_scope "rev" "HEAD " 1 "location" HEAD --
  fi

  local head_sha
  head_sha="$(git -C "${REPO_ROOT}" rev-parse --verify HEAD)"
  local msg_tmp="${TMP_WORK}/head_msg.txt"
  git -C "${REPO_ROOT}" log -1 --format=%B "${head_sha}" > "${msg_tmp}"
  scan_text_file "${msg_tmp}" "HEAD commit ${head_sha:0:7} <msg>" 1 0 "HEAD:${head_sha:0:7}:msg"
}

scan_working_tree() {
  local -a wt_paths=()
  mapfile -d '' -t wt_paths < <(git -C "${REPO_ROOT}" ls-files -z --cached --others --exclude-standard)
  local p
  for p in "${wt_paths[@]}"; do
    [[ -e "${REPO_ROOT}/${p}" || -L "${REPO_ROOT}/${p}" ]] || continue
    check_path "${p}" "worktree " 1 "worktree:${p}"
  done

  if (( ${#wt_paths[@]} > 0 )); then
    scan_git_grep_scope "cached" "worktree " 1 "location" --untracked --
  fi

  if git -C "${REPO_ROOT}" rev-parse --verify HEAD >/dev/null 2>&1; then
    local head_sha
    head_sha="$(git -C "${REPO_ROOT}" rev-parse --verify HEAD)"
    local msg_tmp="${TMP_WORK}/head_msg.txt"
    git -C "${REPO_ROOT}" log -1 --format=%B "${head_sha}" > "${msg_tmp}"
    scan_text_file "${msg_tmp}" "HEAD commit ${head_sha:0:7} <msg>" 1 0 "HEAD:${head_sha:0:7}:msg"
  fi
}

scan_single_commit_outgoing() {
  local sha="$1"
  local short="${sha:0:7}"

  local msg_tmp="${TMP_WORK}/commit_msg_${short}.txt"
  git -C "${REPO_ROOT}" log -1 --format=%B "${sha}" > "${msg_tmp}"
  scan_text_file "${msg_tmp}" "commit ${short} <msg>" 1 0 "commit:${short}:msg"

  local -a changed_paths=()
  mapfile -d '' -t changed_paths < <(
    git -C "${REPO_ROOT}" diff-tree --root --no-commit-id -r --no-renames --diff-filter=ACMR --name-only -z "${sha}"
  )
  (( ${#changed_paths[@]} == 0 )) && return 0

  local p
  for p in "${changed_paths[@]}"; do
    check_path "${p}" "commit ${short} " 1 "commit:${short}:${p}"
  done

  scan_git_grep_scope "rev" "commit " 1 "location" "${sha}" -- "${changed_paths[@]}"
}

scan_pre_push() {
  local -a commits_to_scan=()
  declare -A seen_commits=()

  if [[ ! -t 0 ]]; then
    local local_ref="" local_oid="" remote_ref="" remote_oid=""
    while read -r local_ref local_oid remote_ref remote_oid; do
      [[ -z "${local_oid:-}" ]] && continue
      [[ "${local_oid}" =~ ^0+$ ]] && continue

      local -a rev_args=()
      if [[ "${remote_oid}" =~ ^0+$ ]]; then
        rev_args=("${local_oid}" "--not" "--remotes")
      elif git -C "${REPO_ROOT}" cat-file -e "${remote_oid}^{commit}" 2>/dev/null; then
        rev_args=("${remote_oid}..${local_oid}")
      else
        rev_args=("${local_oid}" "--not" "--remotes")
      fi

      local sha=""
      while IFS= read -r sha; do
        if [[ -n "${sha}" && -z "${seen_commits[${sha}]:-}" ]]; then
          seen_commits["${sha}"]=1
          commits_to_scan+=("${sha}")
        fi
      done < <(git -C "${REPO_ROOT}" rev-list "${rev_args[@]}")
    done
  fi

  # Always cover HEAD (handles `lefthook run pre-push` with empty stdin)
  if git -C "${REPO_ROOT}" rev-parse --verify HEAD >/dev/null 2>&1; then
    local head_sha
    head_sha="$(git -C "${REPO_ROOT}" rev-parse --verify HEAD)"
    if [[ -n "${head_sha}" && -z "${seen_commits[${head_sha}]:-}" ]]; then
      seen_commits["${head_sha}"]=1
      commits_to_scan+=("${head_sha}")
    fi
  fi

  scan_head_tree
  local sha
  for sha in "${commits_to_scan[@]}"; do
    scan_single_commit_outgoing "${sha}"
  done
}

scan_all() {
  scan_working_tree

  # Historical file paths (enforce .env and blacklist rules, skip HOME_PATH_LEAK for already-cleaned history)
  local cur_commit=""
  local line=""
  while IFS= read -r line; do
    if [[ "${line}" == \<\<\<COMMIT:*\>\>\> ]]; then
      cur_commit="${line#\<\<\<COMMIT:}"
      cur_commit="${cur_commit%\>\>\>}"
      continue
    fi
    [[ -z "${line}" ]] && continue
    check_path "${line}" "commit ${cur_commit} " 0 "histpath:${line}"
  done < <(git -C "${REPO_ROOT}" log --all --diff-filter=ACMR --name-only --format='<<<COMMIT:%h>>>')

  # Historical commit messages (fast combined pre-filter, exact attribution only on hits)
  local all_msgs="${TMP_WORK}/all_commit_msgs.txt"
  git -C "${REPO_ROOT}" log --all --format='<<<COMMIT:%h>>>%n%B' > "${all_msgs}"

  local msg_hits="${TMP_WORK}/all_msg_hits.txt"
  : > "${msg_hits}"
  collect_grep_file_hits "${all_msgs}" 0 "${msg_hits}"
  if [[ -s "${msg_hits}" ]]; then
    local matched_shas_file="${TMP_WORK}/matched_msg_shas.txt"
    awk '
      /^<<<COMMIT:[^>]+>>>$/ { cur = substr($0, 11, length($0) - 13); next }
      { print NR ":" cur }
    ' "${all_msgs}" > "${TMP_WORK}/line_to_sha.txt"
    cut -d: -f1 "${msg_hits}" | sort -n -u > "${TMP_WORK}/hit_linenos.txt"
    awk -F: '
      NR == FNR { want[$1] = 1; next }
      ($1 in want) && !seen[$2]++ { print $2 }
    ' "${TMP_WORK}/hit_linenos.txt" "${TMP_WORK}/line_to_sha.txt" > "${matched_shas_file}"

    local msha=""
    while IFS= read -r msha; do
      [[ -z "${msha}" ]] && continue
      local mtmp="${TMP_WORK}/hist_msg_${msha}.txt"
      git -C "${REPO_ROOT}" log -1 --format=%B "${msha}" > "${mtmp}"
      scan_text_file "${mtmp}" "commit ${msha} <msg>" 0 0 "histmsg:${msha}"
    done < "${matched_shas_file}"
  fi

  # Historical blobs across all reachable commits in chunks of 400 SHAs
  local -a all_shas=()
  mapfile -t all_shas < <(git -C "${REPO_ROOT}" rev-list --all)
  local total="${#all_shas[@]}"
  local offset=0
  local chunk_size=400
  while (( offset < total )); do
    local -a chunk=("${all_shas[@]:offset:chunk_size}")
    scan_git_grep_scope "rev" "commit " 0 "pathline" "${chunk[@]}" --
    offset=$((offset + chunk_size))
  done
}

print_report() {
  local mode="$1"
  if (( SKIPPED_MISSING == 1 )); then
    printf '[sloth leak-guard] WARN (%s): SLOTH_ALLOW_MISSING_BLACKLIST=1 set; skipped private blacklist (%d structural violations).\n' \
      "${mode}" "${VIOLATION_COUNT}"
  fi
  if (( VIOLATION_COUNT == 0 )); then
    printf '[sloth leak-guard] PASS (%s): 0 violations (%d private blacklist rules checked).\n' \
      "${mode}" "${RULE_COUNT}"
    return 0
  fi

  local bar="=========================================================================="
  local sep="--------------------------------------------------------------------------"
  {
    printf '\n%s\n' "${bar}"
    printf '[sloth leak-guard] BLOCKED (%s) — %d VIOLATION(S) DETECTED\n' "${mode}" "${VIOLATION_COUNT}"
    printf '%s\n' "${bar}"
    cat "${VIOLATIONS_FILE}"
    printf '%s\n' "${sep}"
    printf '[sloth leak-guard] FAILED (%s): Fix the %d violation(s) above before committing or pushing.\n' \
      "${mode}" "${VIOLATION_COUNT}"
    printf '%s\n\n' "${bar}"
  } >&2
  return 1
}

main() {
  if (( $# < 1 )); then
    usage
    exit 2
  fi

  local mode="$1"
  local msg_file="${2:-}"

  case "${mode}" in
    --staged | --commit-msg | --pre-push | --all) ;;
    *)
      printf "Unknown mode '%s'. Expected --staged, --commit-msg <file>, --pre-push, or --all.\n" "${mode}" >&2
      exit 2
      ;;
  esac

  if [[ "${mode}" == "--commit-msg" && -z "${msg_file}" ]]; then
    printf '%s\n' '--commit-msg requires the path to the commit message file.' >&2
    exit 2
  fi

  load_blacklist "${mode}"

  case "${mode}" in
    --staged)
      scan_staged
      ;;
    --commit-msg)
      scan_commit_msg_file "${msg_file}"
      ;;
    --pre-push)
      scan_pre_push
      ;;
    --all)
      scan_all
      ;;
  esac

  print_report "${mode}"
}

main "$@"
