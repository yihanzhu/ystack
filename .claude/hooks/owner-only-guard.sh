#!/bin/bash
# PreToolUse guard for Bash and WebFetch. Agents read issue, PR, review and
# comment text only through scripts/gh-read.sh, which hides text that the owner
# did not write. Exit 2 blocks the call.
#
# It runs on every Bash call, so it uses bash tests and no subprocess after jq.

export LC_ALL=C

block() {
  echo "Blocked by ystack guard: $1 Use scripts/gh-read.sh NUMBER; it hides text from other accounts." >&2
  exit 2
}

fail() {
  echo "Blocked by ystack guard: $1" >&2
  exit 2
}

command -v jq > /dev/null || fail "jq is missing; the hook needs it to read its input."

# One line each for the tool name and the URL, then the command, which may hold
# line breaks, then a last line "." so that no line break is lost.
if IFS= read -r -d '' input || ! fields=$(
  set -o pipefail
  printf '%s' "$input" | jq -r '
    (.tool_name // ""), (.tool_input.url // "" | gsub("\n"; " ")),
    (.tool_input.command // ""), "." | gsub("\u0000"; "")' 2>/dev/null
); then
  fail "the hook could not read its input."
fi
tool=${fields%%$'\n'*}
rest=${fields#*$'\n'}
url=${rest%%$'\n'*}
rest=${rest#*$'\n'}
cmd=${rest%$'\n.'}

case $tool in
  Bash) [ -n "$cmd" ] || fail "the hook got no command." ;;
  WebFetch) [ -n "$url" ] || fail "the hook got no URL." ;;
  *) [ -n "$cmd$url" ] || fail "the hook got no command and no URL." ;;
esac

# Addresses that return issue, PR, review or comment text from any account.
api_text="api\\.github\\.com/(repos/[^/[:space:]]+/[^/[:space:]]+/(issues|pulls)([/?#[:space:]\"']|\$)|search/issues|graphql|[^[:space:]\"']*/(comments|reviews|timeline)([/?#[:space:]\"']|\$))"
page_text="github\\.com/[^/[:space:]]+/[^/[:space:]]+/(issues|pull|pulls|discussions)([/?#[:space:]\"']|\$)"
url_msg="this address returns issue, PR, review or comment text from any account."

shopt -s nocasematch
if [[ $url =~ $api_text ]] || [[ $url =~ $page_text ]]; then
  block "$url_msg"
fi
# Backslash line breaks are removed, as bash removes them.
cmd=${cmd//$'\\\n'/}
# Every rule below needs `gh` and a space, or a github.com address.
fast='gh[[:space:]]|github\.com'
[[ $cmd =~ $fast ]] || exit 0
shopt -u nocasematch

# GraphQL fields that hold text. A query may span lines or sit in a variable,
# so the whole command is read.
gh_api='gh[[:space:]]+api'
graphql_text='(^|[^A-Za-z0-9_])(body|title)[A-Za-z]*([^A-Za-z0-9_]|$)|userContentEdits'
if [[ $cmd == *graphql* ]] && [[ $cmd =~ $gh_api ]] && [[ $cmd =~ $graphql_text ]]; then
  block "this query reads text from any account."
fi

gh_cli='gh[[:space:]]+(issue|pr|search)[[:space:]]'
gh_view='gh[[:space:]]+(issue|pr)[[:space:]]+view'
view_ok='--json|(^|[[:space:]])(-w|--web)([[:space:]]|$)'
# JSON fields of gh issue, gh pr and gh search that hold text from any account.
text_fields='(^|[^A-Za-z])(body|comments|reviews|latestReviews)([^A-Za-z]|$)'
text_endpoint='/(comments|reviews|timeline|events)([^A-Za-z]|$)'
# One issue or PR, a list of them (of a repository, an organization, the user,
# or all), or an issue search. A repository named issues is not a list.
item_path="(issues|pulls)/[0-9]+([^0-9/]|\$)|(repos/[^/[:space:]]+/[^/[:space:]]+/|orgs/[^/[:space:]]+/|user/|[[:space:]\"']/?)(issues|pulls)([?[:space:]\"']|\$)|search/issues"
template_re='(^|[[:space:]])(-t|--template)([[:space:]=]|$)'
filter_re="(^|[[:space:]])(--jq|-q)([[:space:]]+|=)('[^']*'|\"([^\"\\\\]|\\\\.)*\"|[^[:space:]]+)"
filter_msg="a --jq filter on issues or PRs may name only these fields: number, state, id, node_id, html_url, url, draft, merged, merged_at, created_at, updated_at, closed_at, total_count, user.login, author.login, labels[].name, head.sha, head.ref, base.ref, mergeable, mergeable_state."

# The safe-field check for a jq filter.
safe_leaf='^(number|state|id|node_id|html_url|url|draft|merged|merged_at|created_at|updated_at|closed_at|total_count|mergeable|mergeable_state)$'
safe_path='^(items\.)?(number|state|id|node_id|html_url|url|draft|merged|merged_at|created_at|updated_at|closed_at|total_count|user\.login|author\.login|labels\.name|head\.sha|head\.ref|base\.ref|mergeable|mergeable_state)$'
reduce_words='^(length|keys)$'
pass_words='^(join|tostring|tonumber|sort|unique|reverse|first|last|add|min|max|tojson|ascii_downcase)$'
other_words='^(map|sort_by|unique_by|group_by|min_by|max_by|not|and|or|true|false|null|select|limit|any|all|empty|test|startswith|endswith|contains|index)$'
str_re='"([^"\\]|\\.)*"'
path_re='\.([A-Za-z_][A-Za-z0-9_]*)?(\[[0-9:]*\]|\.[A-Za-z_][A-Za-z0-9_]*|\?)*'
word_re='([A-Za-z_][A-Za-z0-9_]*)([[:space:]]*:)?'
bracket_re='\[[0-9:]*\]'
assign_re='\|=|[-+*/%]=|(^|[^=!<>])=($|[^=])'

# Returns 0 when filter $1 can print only safe fields.
safe_filter() {
  local f=$1 s stage tok norm word n i out_found=false
  local -a stages kinds
  # One safe path alone, such as .head.sha or .[].number, is the most common
  # filter. A case list is much faster than a regex here.
  s=${f#.}
  s=${s#items}
  s=${s#\[\]}
  s=${s#.}
  case $s in
    number | state | id | node_id | html_url | url | draft | merged | merged_at | created_at | \
      updated_at | closed_at | total_count | user.login | author.login | 'labels[].name' | \
      head.sha | head.ref | base.ref | mergeable | mergeable_state) return 0 ;;
  esac
  [[ $f == *'$'* || $f == *'\('* ]] && return 1
  s=$f
  while [[ $s =~ $str_re ]]; do s=${s/"${BASH_REMATCH[0]}"/ }; done
  [[ $s == *'"'* ]] && return 1
  [[ $s =~ $assign_re ]] && return 1
  while [[ $s =~ @([A-Za-z0-9]*) ]]; do
    tok=${BASH_REMATCH[0]}
    [[ $tok =~ ^@(tsv|csv|json|text)$ ]] || return 1
    s=${s/"$tok"/ }
  done
  IFS='|'
  set -f
  # shellcheck disable=SC2206 # Splitting on | is the point; set -f stops globbing.
  stages=($s)
  set +f
  IFS=$' \t\n'
  n=${#stages[@]}
  [ "$n" -gt 0 ] || return 1
  # A kind per stage: "out" prints safe fields or a count; "pass" only reshapes
  # what came before; "mid" iterates or filters, and so prints whole objects
  # when it is the last stage that counts.
  for ((i = 0; i < n; i++)); do
    stage=${stages[i]}
    local has_empty=false has_safe=false has_reduce=false has_select=false has_other=false
    while [[ $stage =~ $path_re ]]; do
      tok=${BASH_REMATCH[0]}
      stage=${stage/"$tok"/ }
      norm=${tok//\?/}
      while [[ $norm =~ $bracket_re ]]; do norm=${norm/"${BASH_REMATCH[0]}"/.}; done
      while [[ $norm == *..* ]]; do norm=${norm//../.}; done
      norm=${norm#.}
      norm=${norm%.}
      if [ -z "$norm" ] || { [ "$norm" = items ] && [[ $tok == *'['* ]]; }; then
        has_empty=true
      elif [[ $norm =~ $safe_path ]]; then
        has_safe=true
      else
        return 1
      fi
    done
    while [[ $stage =~ $word_re ]]; do
      word=${BASH_REMATCH[1]}
      stage=${stage/"${BASH_REMATCH[0]}"/ }
      [ -n "${BASH_REMATCH[2]}" ] && continue
      if [[ $word =~ $safe_leaf ]]; then
        has_safe=true
      elif [[ $word =~ $reduce_words ]]; then
        has_reduce=true
      elif [[ $word =~ $pass_words ]]; then
        :
      elif [[ $word =~ $other_words ]]; then
        has_other=true
        [ "$word" = select ] && has_select=true
      else
        return 1
      fi
    done
    if $has_empty || $has_select; then
      kinds[i]=mid
    elif $has_safe || $has_reduce; then
      kinds[i]=out
    elif $has_other; then
      kinds[i]=mid
    else
      kinds[i]=pass
    fi
  done
  # The last stage that is not "pass" decides what is printed.
  for ((i = n - 1; i >= 0; i--)); do
    [ "${kinds[i]}" = pass ] && continue
    [ "${kinds[i]}" = out ] && out_found=true
    break
  done
  $out_found
}

check_filters() {
  local part=$1 rest=$1 found=false f
  [[ $part == *-t* ]] && [[ $part =~ $template_re ]] && block "a --template can print the body and title."
  [[ $part == *-q* || $part == *--jq* ]] || rest=''
  while [ -n "$rest" ] && [[ $rest =~ $filter_re ]]; do
    found=true
    f=${BASH_REMATCH[4]}
    rest=${rest#*"${BASH_REMATCH[0]}"}
    case $f in
      \'*\') f=${f:1:${#f}-2} ;;
      \"*\") f=${f:1:${#f}-2}; f=${f//\\\"/\"} ;;
    esac
    safe_filter "$f" || block "$filter_msg"
  done
  $found || block "issue and PR objects hold their body and title; filter them with --jq on safe fields."
}

check_part() {
  local part=$1 gh=false
  [[ $part == *gh* || $part == *[Gg][Ii][Tt][Hh][Uu][Bb]* ]] || return 0
  if [[ $part == *gh* ]] && [[ $part == *pr* || $part == *issue* || $part == *search* ]] &&
    [[ $part =~ $gh_cli ]]; then
    gh=true
    [[ $part == *--comments* ]] && block "--comments prints comments from any account."
    if [[ $part == *--json* ]] && [[ $part =~ $text_fields ]]; then
      block "these JSON fields hold text from any account."
    fi
    if [[ $part =~ $gh_view ]] && ! [[ $part =~ $view_ok ]]; then
      block "plain 'gh issue view' and 'gh pr view' print the body."
    fi
  fi
  if [[ $part == *gh* ]] && [[ $part =~ $gh_api ]]; then
    gh=true
    if [[ $part == *comments* || $part == *reviews* || $part == *timeline* || $part == *events* ]] &&
      [[ $part =~ $text_endpoint ]]; then
      block "this endpoint returns comments or reviews."
    fi
    if [[ $part == *issues* || $part == *pulls* ]] && [[ $part =~ $item_path ]]; then
      check_filters "$part"
    fi
  fi
  if ! $gh; then
    shopt -s nocasematch
    if [[ $part =~ $api_text ]] || [[ $part =~ $page_text ]]; then
      block "$url_msg"
    fi
    shopt -u nocasematch
  fi
}

# One command: quoted strings, escaped characters, and other characters up to
# |, ; or &.
part_re="^(\"([^\"\\\\]|\\\\.)*\"|'[^']*'|\\\\.|[^|;&\"'\\\\])*"

# Split into lines in memory: a here-string needs a temporary file in bash 3.2.
set -f
IFS=$'\n'
# shellcheck disable=SC2206 # Splitting on line breaks is the point; set -f stops globbing.
lines=($cmd)
IFS=$' \t\n'
set +f
for line in ${lines[@]+"${lines[@]}"}; do
  [[ $line == *gh[[:space:]]* || $line == *[Gg][Ii][Tt][Hh][Uu][Bb].[Cc][Oo][Mm]* ]] || continue
  # Redirections such as 2>&1 are not command breaks.
  rest=${line//&>/>}
  rest=${rest//>&/>}
  rest=${rest//<&/<}
  while [ -n "$rest" ]; do
    [[ $rest =~ $part_re ]]
    part=${BASH_REMATCH[0]}
    check_part "$part"
    # Drop the part and the character that ended it.
    rest=${rest:$((${#part} + 1))}
  done
done
exit 0
