#!/bin/sh

# prefs.js cleaner for macOS and Linux
# authors: @claustromaniac, @overdodactyl, @earthlng, @9ao9ai9ar
# version: 2.2

# shellcheck disable=SC2015
# SC2015: Note that A && B || C is not if-then-else. C may run when A is true.
# This is just noise for those who know what they are doing.

############################################################################
## Common utility functions shared between updater.sh and prefsCleaner.sh ##
############################################################################

# https://stackoverflow.com/q/1101957
exit_status_definitions() {
    cut -d'#' -f1 <<'EOF'
EX_OK=0           # Successful exit status.
EX_FAIL=1         # Failing exit status.
EX_USAGE=2        # Command line usage error.
EX__BASE=64       # Base value for error messages.
EX_DATAERR=65     # Data format error.
EX_NOINPUT=66     # Cannot open input.
EX_NOUSER=67      # Addressee unknown.
EX_NOHOST=68      # Host name unknown.
EX_UNAVAILABLE=69 # Service unavailable.
EX_SOFTWARE=70    # Internal software error.
EX_OSERR=71       # System error (e.g., can't fork).
EX_OSFILE=72      # Critical OS file missing.
EX_CANTCREAT=73   # Can't create (user) output file.
EX_IOERR=74       # Input/output error.
EX_TEMPFAIL=75    # Temp failure; user is invited to retry.
EX_PROTOCOL=76    # Remote error in protocol.
EX_NOPERM=77      # Permission denied.
EX_CONFIG=78      # Configuration error.
EX_NOEXEC=126     # A file to be executed was found, but it was not an executable utility.
EX_CNF=127        # A utility to be executed was not found.
EX_SIGHUP=129     # A command was interrupted by SIGHUP (1)
EX_SIGINT=130     # A command was interrupted by SIGINT (2)
EX_SIGQUIT=131    # A command was interrupted by SIGQUIT (3)
EX_SIGABRT=134    # A command was interrupted by SIGABRT (6)
EX_SIGKILL=137    # A command was interrupted by SIGKILL (9)
EX_SIGALRM=142    # A command was interrupted by SIGALRM (14)
EX_SIGTERM=143    # A command was interrupted by SIGTERM (15)
EOF
}

# TODO: think of a better name to reflect proper usage as it only works correctly on boolean inputs.
is_set() { # arg: name
    [ "${1:-0}" != 0 ]
}

init() {
    # The --color option of grep is not supported on OpenBSD, neither is it specified in POSIX.
    # To prevent the accidental insertion of SGR commands in the grep output,
    # even when not directed at a terminal, we explicitly set the following 3 environment variables:
    export GREP_COLORS='mt=:ms=:mc=:sl=:cx=:fn=:ln=:bn=:se='
    export GREP_COLOR='0' # Obsolete. Use on macOS and some Unixes or Unix-like operating systems
    :                     # where the provided grep implementations do not support GREP_COLORS.
    export GREP_OPTIONS=  # Obsolete. Use on systems with GNU grep 2.20 or earlier installed.
    # The pipefail option is supported by most current major UNIX shells, with the notable
    # exceptions of dash and ksh88-based shells, and it has been added to SUSv5 (POSIX.1-2024):
    # https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_26_03.
    # BEWARE pitfalls! https://mywiki.wooledge.org/BashPitfalls#pipefail.
    # shellcheck disable=SC3040
    (set -o pipefail >/dev/null 2>&1) && set -o pipefail
    # shellcheck disable=SC2046
    for exit_status in $(exit_status_definitions | cut -d'=' -f2); do
        # https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_08_02
        # When reporting the exit status with the special parameter '?',
        # the shell shall report the full eight bits of exit status available.
        # https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_21
        # exit [n]: If n is specified, but its value is not between 0 and 255 inclusively,
        # the exit status is undefined.
        [ "$exit_status" -ge 0 ] && [ "$exit_status" -le 255 ] || {
            echo 'Undefined exit status in the definitions:' >&2
            exit_status_definitions >&2
            return 70 # Internal software error.
        }
    done &&
        eval $(exit_status_definitions) &&
        eval readonly $(exit_status_definitions | cut -d'=' -f1) ||
        {
            echo 'An unexpected error occurred while evaluating exit status definitions.' >&2
            return 69 # Service unavailable.
        }
    probe_environment
}

print_error() { # args: [ARGUMENT]...
    printf '%s\n' "${RED}ERROR: $*${RESET}" >&2
}

print_warning() { # args: [ARGUMENT]...
    printf '%s\n' "${YELLOW}WARNING: $*${RESET}" >&2
}

print_ok() { # args: [ARGUMENT]...
    printf '%s\n' "${GREEN}OK: $*${RESET}" >&2
}

print_prompt() { # args: [ARGUMENT]...
    printf '%s' "${BLUE}$*${RESET} " >&2
}

print_confirm() { # args: [ARGUMENT]...
    printf '%s' "${RED}$*${RESET} " >&2
}

probe_terminal() {
    if tput setaf bold sgr0 >/dev/null 2>&1; then
        RED=$(tput setaf 1)
        BLUE=$(tput setaf 4)
        BBLUE=$(tput bold setaf 4)
        GREEN=$(tput setaf 2)
        YELLOW=$(tput setaf 3)
        CYAN=$(tput setaf 6)
        RESET=$(tput sgr0)
    else
        RED=
        BLUE=
        BBLUE=
        GREEN=
        YELLOW=
        CYAN=
        RESET=
    fi
}

# FIXME: potential performance issues, rewrite needed.
probe_permissions() {
    if [ "$(id -u)" -eq 0 ]; then
        print_error "You shouldn't run this with elevated privileges (such as with doas/sudo)."
        return "$EX_USAGE"
    elif [ -n "$(find . -user 0)" ]; then
        print_error 'It looks like this script was previously run with elevated privileges.' \
            'You will need to change ownership of the following files to your user:'
        printf '%s\n' "${RED}$(find . -user 0)${RESET}" >&2
        return "$EX_CANTCREAT"
    fi
}

probe_readlink() {
    # Copied verbatim from https://stackoverflow.com/a/29835459.
    # shellcheck disable=all
    rreadlink() (# Execute the function in a *subshell* to localize variables and the effect of `cd`.

        target=$1 fname= targetDir= CDPATH=

        # Try to make the execution environment as predictable as possible:
        # All commands below are invoked via `command`, so we must make sure that `command`
        # itself is not redefined as an alias or shell function.
        # (Note that command is too inconsistent across shells, so we don't use it.)
        # `command` is a *builtin* in bash, dash, ksh, zsh, and some platforms do not even have
        # an external utility version of it (e.g, Ubuntu).
        # `command` bypasses aliases and shell functions and also finds builtins
        # in bash, dash, and ksh. In zsh, option POSIX_BUILTINS must be turned on for that
        # to happen.
        {
            \unalias command
            \unset -f command
        } >/dev/null 2>&1
        [ -n "$ZSH_VERSION" ] && options[POSIX_BUILTINS]=on # make zsh find *builtins* with `command` too.

        while :; do # Resolve potential symlinks until the ultimate target is found.
            [ -L "$target" ] || [ -e "$target" ] || {
                command printf '%s\n' "ERROR: '$target' does not exist." >&2
                return 1
            }
            command cd "$(command dirname -- "$target")" # Change to target dir; necessary for correct resolution of target path.
            fname=$(command basename -- "$target")       # Extract filename.
            [ "$fname" = '/' ] && fname=''               # !! curiously, `basename /` returns '/'
            if [ -L "$fname" ]; then
                # Extract [next] target path, which may be defined
                # *relative* to the symlink's own directory.
                # Note: We parse `ls -l` output to find the symlink target
                #       which is the only POSIX-compliant, albeit somewhat fragile, way.
                target=$(command ls -l "$fname")
                target=${target#* -> }
                continue # Resolve [next] symlink target.
            fi
            break # Ultimate target reached.
        done
        targetDir=$(command pwd -P) # Get canonical dir. path
        # Output the ultimate target's canonical path.
        # Note that we manually resolve paths ending in /. and /.. to make sure we have a normalized path.
        if [ "$fname" = '.' ]; then
            command printf '%s\n' "${targetDir%/}"
        elif [ "$fname" = '..' ]; then
            # Caveat: something like /var/.. will resolve to /private (assuming /var@ -> /private/var), i.e. the '..' is applied
            # AFTER canonicalization.
            command printf '%s\n' "$(command dirname -- "${targetDir}")"
        else
            command printf '%s\n' "${targetDir%/}/$fname"
        fi
    )
    preadlink() { # args: FILE...
        if [ "$#" -le 0 ]; then
            echo 'preadlink: missing operand' >&2
            return "$EX_USAGE"
        else
            while [ "$#" -gt 0 ]; do
                rreadlink "$1"
                shift
            done
        fi
    }
    if command realpath -- . >/dev/null 2>&1; then
        preadlink() {
            command realpath -- "$@"
        }
    elif command readlink -f -- . >/dev/null 2>&1; then
        preadlink() {
            command readlink -f -- "$@"
        }
    elif command greadlink -f -- . >/dev/null 2>&1; then
        preadlink() {
            command greadlink -f -- "$@"
        }
    fi
}

probe_mktemp() {
    if ! command -v mktemp >/dev/null 2>&1; then
        # Copied verbatim from https://unix.stackexchange.com/a/181996.
        mktemp() {
            echo 'mkstemp(template)' |
                m4 -D template="${TMPDIR:-/tmp}/baseXXXXXX"
        }
    fi
}

probe_downloader() {
    pdownloader() { # args: URL...
        missing_pdownloader
    }
    if command -v curl >/dev/null 2>&1; then
        pdownloader() {
            command curl --max-redirs 3 -so "$@"
        }
    elif command -v wget2 >/dev/null 2>&1; then
        pdownloader() {
            command wget2 --max-redirect 3 -qO "$@"
        }
    elif command -v wget >/dev/null 2>&1; then
        pdownloader() {
            command wget --max-redirect 3 -qO "$@"
        }
    fi
}

download_files() { # args: URL...
    # It is not easy to write portable and robust trap commands without side effects.
    # As mktemp creates temporary files that are periodically cleared on any sane system,
    # we leave it to the OS or the user to do the cleaning themselves for simplicity's sake.
    output_temp=$(mktemp) &&
        pdownloader "$output_temp" "$@" >/dev/null 2>&1 &&
        printf '%s\n' "$output_temp" || {
        print_error "Could not download $*."
        return "$EX_UNAVAILABLE"
    }
}

# TODO: add -V option to display script version?
script_version() { # arg: {updater.sh|prefsCleaner.sh}
    # Why not [[:digit:]] or [0-9]: https://unix.stackexchange.com/a/654391.
    # Short answer: they are locale-dependent.
    version=$(
        sed -n '2,10s/.*version:[[:blank:]]*\([0123456789]\{1,\}\.[0123456789]\{1,\}\).*/\1/p' "$1"
    ) &&
        [ "$(printf '%s' "$version" | wc -w)" -eq 1 ] &&
        printf '%s\n' "$version" || {
        print_error "Could not determine script version from the first 10 lines of the file $1."
        return "$EX_SOFTWARE"
    }
}

########################################
## prefsCleaner.sh specific functions ##
########################################

probe_environment() {
    probe_terminal &&
        probe_permissions &&
        probe_readlink &&
        probe_mktemp &&
        probe_downloader || {
        print_error 'Encountered issues while trying to initialize the environment.'
        return "$EX_CONFIG"
    }
}

missing_pdownloader() {
    print_warning 'No curl or wget detected.' 'Automatic self-update disabled!'
    AUTOUPDATE=false
}

usage() {
    cat <<EOF

Usage: $(basename "$0") [-ds]

Optional Arguments:
    -s           Start immediately
    -d           Don't auto-update prefsCleaner.sh
EOF
}

help() {
    cat <<'EOF'
    
This script creates a backup of your prefs.js file before doing anything.
It should be safe, but you can follow these steps if something goes wrong:

1. Make sure Firefox is closed.
2. Delete prefs.js in your profile folder.
3. Delete Invalidprefs.js if you have one in the same folder.
4. Rename or copy your latest backup to prefs.js.
5. Run Firefox and see if you notice anything wrong with it.
6. If you do notice something wrong, especially with your extensions, and/or with the UI, go to about:support, and restart Firefox with add-ons disabled. Then, restart it again normally, and see if the problems were solved.
If you are able to identify the cause of your issues, please bring it up on the arkenfox user.js GitHub repository.

EOF
}

show_banner() {
    cat <<'EOF'



                   ╔══════════════════════════╗
                   ║     prefs.js cleaner     ║
                   ║    by claustromaniac     ║
                   ║           v2.2           ║
                   ╚══════════════════════════╝

This script should be run from your Firefox profile directory.

It will remove any entries from prefs.js that also exist in user.js.
This will allow inactive preferences to be reset to their default values.

This Firefox profile shouldn't be in use during the process.

EOF
}

update_script() {
    master_prefs_cleaner=$(
        download_files 'https://raw.githubusercontent.com/arkenfox/user.js/master/prefsCleaner.sh'
    ) || {
        echo 'Error! Could not download prefsCleaner.sh' >&2
        return "$EX_UNAVAILABLE"
    }
    local_version=$(script_version "$SCRIPT_FILE") &&
        master_version=$(script_version "$master_prefs_cleaner") || return
    if [ "${local_version%%.*}" -eq "${master_version%%.*}" ] &&
        [ "${local_version#*.}" -lt "${master_version#*.}" ] ||
        [ "${local_version%%.*}" -lt "${master_version%%.*}" ]; then # Update available.
        mv "$master_prefs_cleaner" "$SCRIPT_FILE" &&
            chmod u+r+x "$SCRIPT_FILE" &&
            "$SCRIPT_FILE" -d "$@"
    fi
}

start() {
    if [ ! -e user.js ]; then
        printf '\n%s\n' 'user.js not found in the current directory.' >&2
        return "$EX_NOINPUT"
    elif [ ! -e prefs.js ]; then
        printf '\n%s\n' 'prefs.js not found in the current directory.' >&2
        return "$EX_NOINPUT"
    fi
    check_firefox_running
    mkdir -p prefsjs_backups
    bakfile="prefsjs_backups/prefs.js.backup.$(date +"%Y-%m-%d_%H%M")"
    mv prefs.js "$bakfile" || {
        printf '\n%s\n%s\n' 'Operation aborted.' \
            "Reason: Could not create backup file $bakfile" >&2
        return "$EX_CANTCREAT"
    }
    printf '\n%s\n' "prefs.js backed up: $bakfile"
    echo 'Cleaning prefs.js...'
    clean "$bakfile"
    printf '\n%s\n' 'All done!'
}

check_firefox_running() {
    # There are many ways to see if firefox is running or not, some more reliable than others.
    # This isn't elegant and might not be future-proof,
    # but should at least be compatible with any environment.
    while [ -e lock ]; do
        printf '\n%s%s\n\n' 'This Firefox profile seems to be in use. ' \
            'Close Firefox and try again.' >&2
        printf 'Press any key to continue.' >&2
        read -r REPLY
    done
}

# FIXME: should also accept single quotes.
clean() {
    prefexp="user_pref[     ]*\([     ]*[\"']([^\"']+)[\"'][     ]*,"
    known_prefs=$(
        grep -E "$prefexp" user.js |
            awk -F'["]' '/user_pref/{ print "\"" $2 "\"" }' |
            sort |
            uniq
    )
    unneeded_prefs=$(
        printf '%s\n' "$known_prefs" |
            grep -E -f - "$1" |
            grep -E -e "^$prefexp"
    )
    printf '%s\n' "$unneeded_prefs" | grep -v -f - "$1" >prefs.js
}

# TODO: place inside main function.
probe_permissions &&
    probe_downloader &&
    probe_readlink ||
    exit
SCRIPT_FILE=$(preadlink "$0") && [ -f "$SCRIPT_FILE" ] || exit
AUTOUPDATE=true
QUICKSTART=false
while getopts 'sd' opt; do
    case $opt in
        s)
            QUICKSTART=true
            ;;
        d)
            AUTOUPDATE=false
            ;;
        \?)
            usage
            ;;
    esac
done
## change directory to the Firefox profile directory
cd "$(dirname "${SCRIPT_FILE}")" || exit
probe_permissions || exit
[ "$AUTOUPDATE" = true ] && update_script "$@"
show_banner
[ "$QUICKSTART" = true ] && start
printf '\n%s\n\n' \
    'In order to proceed, select a command below by entering its corresponding number.'
while :; do
    printf '1) Start
2) Help
3) Exit
#? ' >&2
    while read -r REPLY; do
        case $REPLY in
            1)
                start
                ;;
            2)
                usage
                help
                ;;
            3)
                exit
                ;;
            '')
                break
                ;;
            *)
                :
                ;;
        esac
        printf '#? ' >&2
    done
done
