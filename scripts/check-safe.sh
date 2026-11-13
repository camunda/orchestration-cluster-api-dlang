#!/bin/sh
# Every D module is @safe: it must carry a module-level `@safe:`, and may not
# switch the rest of a module off with `@system:` or `@trusted:`. Escapes go
# in small `@trusted` lambdas or functions. Runs before each `dub build` and
# `dub test` (dub.json preBuildCommands), so a violation fails the build.
cd "$(dirname "$0")/.." || exit 2
# Both packages: the typed SDK (source/) and :runtime (runtime/source/).
SRC="source runtime/source"
SAFEIO=runtime/source/camunda/safeio.d
status=0
for f in $(grep -rL '^@safe:' $SRC --include='*.d'); do
    echo "$f(1): Error: module is missing a module-level \`@safe:\` (see scripts/check-safe.sh)" >&2
    status=1
done
if grep -rnE '^[[:space:]]*@(system|trusted)[[:space:]]*:' $SRC --include='*.d' >&2; then
    echo "Error: \`@system:\`/\`@trusted:\` turn off @safe for the rest of a scope; mark the smallest function or lambda instead" >&2
    status=1
fi
# `@system` code is only allowed at the C boundary (`extern (C)` prototypes);
# everything else is @safe or a small @trusted.
if grep -rnE '(^|[^/`[:alnum:]])@system\b' $SRC --include='*.d' | grep -vE ':[[:space:]]*(///|//)' | grep -v 'extern (C)' >&2; then
    echo "Error: \`@system\` is only allowed on \`extern (C)\` declarations; use @safe, or @trusted on the smallest function or lambda" >&2
    status=1
fi
trusted() { grep -nE '(^|[^/`[:alnum:]])@trusted\b' "$@" | grep -vE ':[[:space:]]*(///|//)'; }
ratchet() { # name count budget-file [what]
    budget=$(cat "$3")
    what=${4:-\`@trusted\`}
    if [ "$2" -gt "$budget" ]; then
        echo "Error: $2 $what $1, budget is $budget ($3); make the code safe, or justify the escape and raise the budget" >&2
        status=1
    elif [ "$2" -lt "$budget" ]; then
        echo "check-safe: $2 $what $1, below the budget of $budget; lower $3 to $2" >&2
    fi
}
ratchet "outside safeio.d" "$(trusted -r $SRC --include='*.d' | grep -c -v "^$SAFEIO:")" scripts/trusted-budget
ratchet "in safeio.d" "$(trusted $SAFEIO | wc -l | tr -d ' ')" scripts/trusted-budget-safeio
# The "E profile": threads start through safeio's `spawn`/`spawnDaemon`.
# Outside safeio.d there are no raw threads, no `__gshared` and no unions.
code() { grep -rnE "$1" $SRC --include='*.d' | grep -v "^$SAFEIO:" | grep -vE ':[0-9]+:[[:space:]]*(///|//)'; }
if code '\bnew Thread\b|\bisDaemon\b|\bstd\.concurrency\b' >&2; then
    echo "Error: start threads with camunda.safeio.spawn/spawnDaemon (sendable arguments only)" >&2
    status=1
fi
if code '\b__gshared\b|(^|[^[:alnum:]_])union\b' >&2; then
    echo "Error: \`__gshared\` and unions are only allowed in safeio.d; use \`shared\` with Locked/atomics, or std.sumtype" >&2
    status=1
fi
ratchet "outside safeio.d" "$(code '\bassumeIsolated\(' | wc -l | tr -d ' ')" scripts/isolation-budget "\`assumeIsolated\` calls"
if ! find $SRC -name '*.d' | sort | xargs awk '
    FNR == 1 { ok = 0 }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*\/\// { ok = 1; next }
    /(^|[^\/`[:alnum:]])@trusted([^[:alnum:]_]|$)|[.]assumeIsolated\(/ {
        if (!ok && FILENAME !~ /safeio[.]d$/ || !ok && $0 ~ /@trusted/) { printf "%s(%d): Error: `@trusted` or `assumeIsolated` without a comment above it saying why it is safe\n", FILENAME, FNR > "/dev/stderr"; bad = 1 }
        if ($0 ~ /[;{}][[:space:]]*$/) ok = 0
        next
    }
    /[;{}][[:space:]]*$/ { ok = 0 }
    END { exit bad }'; then
    status=1
fi
exit $status
