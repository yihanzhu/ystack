#!/bin/bash
# Checks scripts/check-public.sh against a scratch repository with fake terms.
# Needs the pinned gitleaks: run scripts/get-gitleaks.sh first.
set -u
export LC_ALL=C

check="$(git rev-parse --show-toplevel)/scripts/check-public.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
repo=$scratch/repo
failures=0

fake_terms=$'# fake terms for this test\nZebraquill\nmoonfjord'
fake_token="ghp_$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 36)"
fake_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
printf '%s\n' zebraquill moonfjord "$fake_token" "$fake_password" config.txt notes.txt \
  > "$scratch/must-not-show"

# Runs check-public.sh in the scratch repo as CI would. $1 name, $2 wanted exit,
# $3 text the output must hold ("" for none), then the check's arguments.
expect() {
  local name=$1 want=$2 needle=$3 out got
  shift 3
  out=$(cd "$repo" && GITHUB_ACTIONS=true "$check" "$@" 2>&1)
  got=$?
  if [ "$got" -ne "$want" ]; then
    echo "not ok - $name: exit $got, want $want"
    printf '%s\n' "$out" | grep -v -i -F -f "$scratch/must-not-show" | sed 's/^/#   /'
    failures=$((failures + 1))
  elif printf '%s\n' "$out" | grep -q -i -F -f "$scratch/must-not-show"; then
    echo "not ok - $name: the output shows a term or the token"
    failures=$((failures + 1))
  elif [ -n "$needle" ] && ! printf '%s\n' "$out" | grep -q -F -- "$needle"; then
    echo "not ok - $name: the output lacks '$needle'"
    printf '%s\n' "$out" | sed 's/^/#   /'
    failures=$((failures + 1))
  else
    echo "ok - $name"
  fi
}

commit_all() {
  git -C "$repo" add -A
  git -C "$repo" -c core.hooksPath=/dev/null commit -q --allow-empty -m "$1"
}

tip() {
  git -C "$repo" rev-parse HEAD
}

git init -q "$repo"
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
printf 'plain text\n' > "$repo/readme.txt"
commit_all 'first commit'
base=$(tip)

export YSTACK_BLOCKED_TERMS_FILE="$scratch/no-such-file"
unset YSTACK_BLOCKED_TERMS
expect 'missing term list' 2 'no term list' tree
YSTACK_BLOCKED_TERMS='' expect 'empty term list' 2 'is empty' tree
YSTACK_BLOCKED_TERMS=$'ab\nmoonfjord' expect 'too-short term' 2 'term 1 is shorter' tree
printf '%s\n' "$fake_terms" > "$scratch/terms.txt"
YSTACK_BLOCKED_TERMS_FILE="$scratch/terms.txt" expect 'term list from a file' 0 'tree clean' tree

export YSTACK_BLOCKED_TERMS="$fake_terms"
expect 'clean tree' 0 'tree clean' tree
expect 'clean index' 0 'staged clean' staged
expect 'clean range' 0 'range clean' range "$base" HEAD

printf 'one\nNotes about ZEBRAQUILL here\n' > "$repo/notes.txt"
commit_all 'add notes'
expect 'term in a file, other case' 1 "of 'git ls-tree -r HEAD', line 2" tree
expect 'term added in a commit' 1 ', line 2' range "$base" HEAD
git -C "$repo" rm -q notes.txt
commit_all 'remove notes'
expect 'term removed again: tree' 0 'tree clean' tree
expect 'term in history' 1 'adds or removes a blocked term' history
notes_commit=$(git -C "$repo" rev-parse HEAD~1)
main_tip=$(tip)
git -C "$repo" checkout -q -b side "$notes_commit"
commit_all 'side work that still holds the old notes'
expect 'old content put back into the tree' 1 "of 'git ls-tree -r" range "$main_tip" HEAD
git -C "$repo" rm -q notes.txt
commit_all 'side work removes the old notes'
expect 'old content only in an earlier commit' 0 'range clean' range "$main_tip" HEAD
git -C "$repo" checkout -q -
expect 'term in an earlier commit of the range' 1 "of 'git rev-list --objects" range "$base" HEAD
base=$(tip)

mkdir -p "$repo/moonfjord-docs"
: > "$repo/moonfjord-docs/empty.txt"
git -C "$repo" add -A
expect 'term in a staged path' 1 "of 'git ls-files -s'" staged
commit_all 'add an empty file with a blocked path'
git -C "$repo" rm -q -r moonfjord-docs
commit_all 'remove it'
expect 'term in a path of an earlier commit' 1 'a path of commit' range "$base" HEAD
base=$(tip)

commit_all 'mention moonfjord in a message'
expect 'term in a commit message' 1 'the message of commit' range "$base" HEAD
base=$(tip)

printf 'Subject\n\nBody with zebraquill\n' > "$scratch/message.txt"
expect 'term in message text' 1 'the message text, line 3' message "$scratch/message.txt"
printf 'Subject\n\nA clean body\n' > "$scratch/message.txt"
expect 'clean message text' 0 'message clean' message "$scratch/message.txt"

printf 'head\0zebraquill\0tail' > "$repo/data.bin"
commit_all 'add binary data'
expect 'term in a binary file' 1 "of 'git ls-tree -r HEAD'" tree
git -C "$repo" rm -q data.bin
commit_all 'remove binary data'

printf 'moonfjord\n' > "$repo/-"
commit_all 'add a file named -'
expect 'term in a file named -' 1 "of 'git ls-tree -r HEAD'" tree
git -C "$repo" rm -q -- -
commit_all 'remove the file named -'

ln -s zebraquill-target "$repo/link"
git -C "$repo" add link
expect 'term in a staged symlink target' 1 "of 'git ls-files -s', line 1" staged
commit_all 'add a link'
expect 'term in a symlink target' 1 "of 'git ls-tree -r HEAD'" tree
git -C "$repo" rm -q link
commit_all 'remove the link'

{ echo zebraquill; head -c 300000 /dev/zero | tr '\0' 'x'; echo; } > "$repo/big.txt"
commit_all 'add a big file'
git -C "$repo" rm -q big.txt
commit_all 'remove the big file'
expect 'term early in a big file of the range' 1 "of 'git rev-list --objects" range "$base" HEAD
base=$(tip)

git -C "$repo" update-index --add --cacheinfo "160000,$(tip),sub"
expect 'submodule in the index' 1 'is a submodule' staged
git -C "$repo" rm -q --cached sub

printf 'token = "%s"\n' "$fake_token" > "$repo/config.txt"
git -C "$repo" add config.txt
expect 'secret in a staged file' 1 'a secret (github-pat) is in entry' staged
commit_all 'add config'
expect 'secret in the tree' 1 'a secret (github-pat) is in entry' tree
git -C "$repo" rm -q config.txt
commit_all 'remove config'
expect 'secret in an earlier commit of the range' 1 'a secret (github-pat)' range "$base" HEAD
base=$(tip)

printf 'token = "%s" # gitleaks:allow\n' "$fake_token" > "$repo/allowed.txt"
commit_all 'add a secret marked allowed'
expect 'inline allow comment is ignored' 1 'a secret (github-pat)' tree
git -C "$repo" rm -q allowed.txt
commit_all 'remove it'
base=$(tip)

commit_all "token $fake_token"
expect 'secret in a commit message' 1 'the message of commit' range "$base" HEAD
base=$(tip)

mkdir -p "$repo/moonfjord"
printf 'token = "%s"\n' "$fake_token" > "$repo/moonfjord/key.txt"
commit_all 'add a secret under a blocked path'
expect 'secret under a blocked path' 1 "of 'git ls-tree -r" tree

printf 'Subject\n\ntoken %s\n' "$fake_token" > "$scratch/message.txt"
expect 'secret in message text' 1 'the message text' message "$scratch/message.txt"

git -C "$repo" rm -q -r moonfjord
nuget='<configuration><packageSourceCredentials><feed>'
nuget+="<add key=\"ClearTextPassword\" value=\"$fake_password\" />"
nuget+='</feed></packageSourceCredentials></configuration>'
printf '%s\n' "$nuget" > "$repo/settings.xml"
commit_all 'add a password under a neutral name'
expect 'path rule does not fire on another name' 0 'tree clean' tree
git -C "$repo" mv settings.xml NuGet.Config
commit_all 'rename it to the name the rule covers'
expect 'path rule fires on its file name' 1 'a secret (nuget-config-password)' tree

# A fake gitleaks shows that an empty report or a scanner error never passes.
fake_cache=$scratch/fake-cache
mkdir -p "$fake_cache/ystack/gitleaks-8.30.1"
fake_gitleaks=$fake_cache/ystack/gitleaks-8.30.1/gitleaks
cat > "$fake_gitleaks" <<'FAKE'
#!/bin/bash
while [ $# -gt 0 ]; do
  [ "$1" = --report-path ] && printf '[]' > "$2"
  shift
done
exit 3
FAKE
chmod +x "$fake_gitleaks"
XDG_CACHE_HOME=$fake_cache expect 'leaks reported with an empty report' 2 'report is empty' message "$scratch/message.txt"
printf '#!/bin/bash\nexit 1\n' > "$fake_gitleaks"
XDG_CACHE_HOME=$fake_cache expect 'scanner error' 2 'gitleaks could not run (exit 1)' message "$scratch/message.txt"

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
