# known_differences.sh - reading a known-differences file against a particular reference
#
# Sourced by the compare scripts rather than run.  It exists because a recorded difference is not
# always a fact about libpng: sometimes it is a fact about *this* libpng, the one the suite happens
# to be comparing against.
#
# The distinction became unavoidable once the suite started running against more than one reference.
# A distribution ships whatever version it shipped — Debian stable carries 1.6.39 — while a
# development machine has whatever is current.  Those two disagree with each other in places, and a
# difference recorded against one of them is then wrong about the other in one of two ways: either
# it exempts a case that now matches, which hides whatever regresses into it, or the run reports it
# as stale and fails, which is what a suite does when it is being told something untrue.
#
# So an entry may carry a guard naming the reference versions it is a claim about:
#
#     [>=1.6.47] meta-palette-hist.png The reference refuses hIST wherever it appears ...
#
# An entry with no guard is a claim about every reference, which is what most of them are.  A guard
# that does not hold makes the entry *inactive*: it neither exempts a difference nor counts as
# stale, because it is not making a claim about the reference in the room.
#
# Guards are versions rather than probes, and that is a deliberate limit.  A probe would be more
# faithful — the project's method everywhere else — but a probe of "does this reference refuse hIST"
# is the very comparison the suite is running, so it would answer the question by assuming it.  A
# version is the one fact about the reference that can be read without asking it to decode anything.

# The reference version, as major.minor.patch, or empty when it could not be determined.
SPNG_REFERENCE_VERSION="${SPNG_REFERENCE_VERSION:-}"

# Compares two dotted versions.  Prints -1, 0 or 1 for less, equal and greater.
spng_compare_versions() {
    awk -v left="$1" -v right="$2" 'BEGIN {
        split(left, l, ".")
        split(right, r, ".")

        for (i = 1; i <= 3; i++) {
            li = (l[i] == "" ? 0 : l[i]) + 0
            ri = (r[i] == "" ? 0 : r[i]) + 0

            if (li < ri) { print -1; exit }
            if (li > ri) { print 1; exit }
        }

        print 0
    }'
}

# Whether a guard such as ">=1.6.47" holds for the reference in use.
#
# An unreadable reference version makes every guard hold: refusing to apply guarded entries because
# the version could not be read would turn one unknown into a suite full of failures, and the entries
# were written because the difference was seen.
spng_guard_holds() {
    guard="$1"

    if [ -z "$SPNG_REFERENCE_VERSION" ]; then
        return 0
    fi

    case "$guard" in
        '>='*) operator='>='; wanted=${guard#>=} ;;
        '<='*) operator='<='; wanted=${guard#<=} ;;
        '>'*)  operator='>';  wanted=${guard#>} ;;
        '<'*)  operator='<';  wanted=${guard#<} ;;
        '='*)  operator='=';  wanted=${guard#=} ;;
        *)
            echo "known differences: unreadable guard [$guard]" >&2
            return 0
            ;;
    esac

    order=$(spng_compare_versions "$SPNG_REFERENCE_VERSION" "$wanted")

    case "$operator" in
        '>=') [ "$order" -ge 0 ] ;;
        '<=') [ "$order" -le 0 ] ;;
        '>')  [ "$order" -gt 0 ] ;;
        '<')  [ "$order" -lt 0 ] ;;
        '=')  [ "$order" -eq 0 ] ;;
    esac
}

# Writes the entries that apply to this reference, guards removed, to standard output.
#
# The result is a file in the original format, so a caller that had one has one still: what changes
# is which lines are in it.  A caller with no known-differences file gets an empty one.
spng_active_differences() {
    source_file="$1"
    output="$2"

    : > "$output"

    [ -n "$source_file" ] && [ -f "$source_file" ] || return 0

    while IFS= read -r line; do
        case "$line" in
            ''|\#*)
                continue
                ;;
            \[*)
                guard=${line%%]*}
                guard=${guard#[}
                rest=${line#*] }

                if spng_guard_holds "$guard"; then
                    printf '%s\n' "$rest" >> "$output"
                fi
                ;;
            *)
                printf '%s\n' "$line" >> "$output"
                ;;
        esac
    done < "$source_file"
}
