#!/bin/sh

# prefs.js cleaner for macOS, Linux and other Unix operating systems
# authors: @claustromaniac, @earthlng, @9ao9ai9ar
# version: 3.0

# shellcheck disable=SC2015
# SC2015: Note that A && B || C is not if-then-else. C may run when A is true.
# This is just noise for those who know what they are doing.

# IMPORTANT! The version string must be between the 2nd and 10th lines,
# inclusive, of this file, and must be of the format "version: MAJOR.MINOR"
# (spaces after the colon are optional).

# IMPORTANT! ARKENFOX_PREFS_CLEANER_NAME must be synced to the name of this file!
# This is so that we may determine if the script is sourced or not by
# comparing it to the basename of the canonical path of $0.
[ -z "$ARKENFOX_PREFS_CLEANER_NAME" ] &&
    readonly ARKENFOX_PREFS_CLEANER_NAME='prefsCleaner.sh'

###############################################################################
####                   === Common utility functions ===                    ####
#### Code that is shared between updater.sh and prefsCleaner.sh, inlined   ####
#### and duplicated only to maintain the same file count as before.        ####
###############################################################################

# https://stackoverflow.com/q/1101957
exit_status_definitions() {
    cut -d'#' -f1 <<'EOF'
EX_OK=0           # Successful exit status.
EX_FAIL=1         # Failed exit status.
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
EX_SIGHUP=129     # A command was interrupted by SIGHUP (1).
EX_SIGINT=130     # A command was interrupted by SIGINT (2).
EX_SIGQUIT=131    # A command was interrupted by SIGQUIT (3).
EX_SIGABRT=134    # A command was interrupted by SIGABRT (6).
EX_SIGKILL=137    # A command was interrupted by SIGKILL (9).
EX_SIGALRM=142    # A command was interrupted by SIGALRM (14).
EX_SIGTERM=143    # A command was interrupted by SIGTERM (15).
EOF
}

init() {
    # https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_26_03
    # The pipefail option, included in POSIX.1-2024 (SUSv5),
    # has long been supported by most major Unix shells,
    # with the notable exceptions of dash and ksh88-based shells.
    # BEWARE OF PITFALLS: https://mywiki.wooledge.org/BashPitfalls#set_-euo_pipefail.
    # shellcheck disable=SC3040
    (set -o pipefail >/dev/null 2>&1) && set -o pipefail
    # The --color option of grep is not supported on OpenBSD,
    # nor is it specified in POSIX.
    # To prevent the accidental insertion of SGR commands in the grep output,
    # even when not directed at a terminal,
    # we explicitly set the following three environment variables:
    export GREP_COLORS='mt=:ms=:mc=:sl=:cx=:fn=:ln=:bn=:se='
    export GREP_COLOR='0' # Obsolete. Use on macOS and some Unix operating systems
    :                     # where the provided grep implementations do not support GREP_COLORS.
    export GREP_OPTIONS=  # Obsolete. Use on systems with GNU grep 2.20 or earlier installed.
    while IFS='=' read -r name code; do
        # https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_08_02
        # When reporting the exit status with the special parameter '?',
        # the shell shall report the full eight bits of exit status available.
        # https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_21
        # exit [n]: If n is specified, but its value is not between 0 and 255
        # inclusively, the exit status is undefined.
        [ "$code" -ge 0 ] && [ "$code" -le 255 ] || {
            printf '%s %s\n' 'Undefined exit status in the definition:' \
                "$name=$code." >&2
            return 70 # Internal software error.
        }
        eval "$name=" || continue # $name is readonly.
        eval readonly '"$name=$code"' || {
            echo 'An unexpected error occurred' \
                'while evaluating exit status definitions.' >&2
            return 69 # Service unavailable.
        }
    done <<EOF
$(exit_status_definitions)
EOF
    probe_environment
}

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
    printf '%s ' "${BLUE}$*${RESET}" >&2
}

print_confirm() { # args: [ARGUMENT]...
    printf '%s ' "${BBLUE}$*${RESET}" >&2
}

probe_terminal() {
    if tput setaf bold sgr0 >/dev/null 2>&1; then
        RED=$(tput setaf 1)
        BLUE=$(tput setaf 4)
        BBLUE=$(tput bold setaf 4)
        GREEN=$(tput setaf 2)
        YELLOW=$(tput setaf 3)
        RESET=$(tput sgr0)
    else
        RED=
        BLUE=
        BBLUE=
        GREEN=
        YELLOW=
        RESET=
    fi
}

probe_run_user() {
    if [ "$(id -u)" -eq 0 ]; then
        print_error "You shouldn't run this with elevated privileges" \
            '(such as with doas/sudo).'
        return "$EX_USAGE"
    fi
}

probe_readlink() {
    if command realpath -- . >/dev/null 2>&1; then
        preadlink() { # args: FILE...
            command realpath -- "$@"
        }
    elif command readlink -f -- . >/dev/null 2>&1; then
        preadlink() { # args: FILE...
            command readlink -f -- "$@"
        }
    elif command greadlink -f -- . >/dev/null 2>&1; then
        preadlink() { # args: FILE...
            command greadlink -f -- "$@"
        }
    else
        print_warning 'Neither realpath nor readlink' \
            'with support for the -f option are found on your system.' \
            'Falling back to using the preadlink custom implementation.'
    fi
}

probe_mktemp() {
    if ! command -v mktemp >/dev/null 2>&1; then
        if command -v m4 >/dev/null 2>&1; then
            print_warning 'mktemp is not found on your system.' \
                "Substituting m4's mkstemp macro for this missing utility."
            # Copied verbatim from https://unix.stackexchange.com/a/181996.
            mktemp() {
                echo 'mkstemp(template)' |
                    m4 -D template="${TMPDIR:-/tmp}/baseXXXXXX"
            }
        else
            missing_mktemp
        fi
    fi
}

probe_downloader() {
    if command -v curl >/dev/null 2>&1; then
        pdownloader() { # args: FILE URL...
            command curl --max-redirs 3 -so "$@"
        }
    elif command -v wget >/dev/null 2>&1; then
        pdownloader() { # args: FILE URL...
            command wget --max-redirect 3 -qO "$@"
        }
    else
        missing_pdownloader
    fi
}

download_files() { # args: URL...
    # It is not easy to write portable trap commands without side effects.
    # As mktemp creates temporary files that are periodically cleared on any
    # sane system, we leave it to the OS or the user to do the cleaning
    # themselves for simplicity's sake.
    output_temp=$(mktemp) &&
        pdownloader "$output_temp" "$@" >/dev/null 2>&1 &&
        printf '%s\n' "$output_temp" || {
        print_error "Could not download $*."
        return "$EX_UNAVAILABLE"
    }
}

script_version() { # arg: {updater.sh|prefsCleaner.sh}
    # Why not [[:digit:]] or [0-9]: https://unix.stackexchange.com/a/654391.
    # Short answer: they are locale-dependent.
    version_format='[0123456789]\{1,\}\.[0123456789]\{1,\}'
    version=$(
        sed -n "2,10s/.*version:[[:blank:]]*\($version_format\).*/\1/p" "$1"
    ) &&
        [ "$(printf '%s' "$version" | wc -w)" -eq 1 ] &&
        printf '%s\n' "$version" || {
        print_error "Could not determine script version from the file $1."
        return "$EX_SOFTWARE"
    }
}

###############################################################################
####              === prefsCleaner.sh specific functions ===               ####
###############################################################################

probe_environment() {
    probe_terminal &&
        probe_run_user &&
        probe_readlink &&
        probe_mktemp &&
        probe_downloader || {
        print_error 'Encountered issues while initializing the environment.'
        return "$EX_CONFIG"
    }
}

missing_mktemp() {
    print_warning 'No mktemp or m4 detected.' 'Automatic self-update disabled!'
    AUTOUPDATE=false
}

missing_pdownloader() {
    print_warning 'No curl or wget detected.' 'Automatic self-update disabled!'
    AUTOUPDATE=false
}

main() {
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
    # Change directory to the Firefox profile directory.
    cd "$SCRIPT_DIR" || exit
    # TODO: Add an option to skip all actions catering to improper usage?
    # TODO: Search user.js, userjs_diff/ and userjs_backups/ only?
    # FIXME: File ownership under SCRIPT_DIR should also be checked accordingly
    #  before running update_script.
    root_owned_files=$(find . -user 0)
    if [ -n "$root_owned_files" ]; then
        print_error 'It looks like this script was previously run' \
            'with elevated privileges.' \
            'You will need to change ownership of' \
            'the following files to your user:' \
            "$(printf '\n\b')$root_owned_files"
        return "$EX_CANTCREAT"
    fi
    [ "$AUTOUPDATE" = true ] && update_script "$@"
    show_banner
    [ "$QUICKSTART" = true ] && start
    printf '\n%s %s\n\n' 'In order to proceed,' \
        'select a command below by entering its corresponding number.'
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
}

usage() {
    cat <<EOF

Usage: $ARKENFOX_PREFS_CLEANER_NAME [-ds]

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
        download_files \
            'https://raw.githubusercontent.com/arkenfox/user.js/master/prefsCleaner.sh'
    ) || {
        print_error "Could not download prefsCleaner.sh."
        return "$EX_UNAVAILABLE"
    }
    local_version=$(script_version "$SCRIPT_PATH") &&
        master_version=$(script_version "$master_prefs_cleaner") || return
    if [ "${local_version%%.*}" -eq "${master_version%%.*}" ] &&
        [ "${local_version#*.}" -lt "${master_version#*.}" ] ||
        [ "${local_version%%.*}" -lt "${master_version%%.*}" ]; then # Update available.
        mv "$master_prefs_cleaner" "$SCRIPT_PATH" &&
            chmod u+r+x "$SCRIPT_PATH" &&
            "$SCRIPT_PATH" -d "$@"
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
    # There are many ways to see if firefox is running or not,
    # some more reliable than others.
    # This isn't elegant and might not be future-proof,
    # but should at least be compatible with any environment.
    while [ -e lock ]; do
        printf '\n%s%s\n\n' 'This Firefox profile seems to be in use. ' \
            'Close Firefox and try again.' >&2
        print_prompt 'Press any key to continue.'
        read -r REPLY
    done
}

# FIXME: Should also accept single quotes.
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

init
init_status=$?
SCRIPT_PATH=$(preadlink "$0") &&
    SCRIPT_DIR=$(dirname "$SCRIPT_PATH") &&
    SCRIPT_NAME=$(basename "$SCRIPT_PATH") || {
    echo 'Something unexpected happened' \
        'while trying to resolve the script path and name.' >&2
    exit 69 # Service unavailable.
}
if [ "$SCRIPT_NAME" = "$ARKENFOX_PREFS_CLEANER_NAME" ]; then
    # This script is likely executed, not sourced.
    [ "$init_status" -eq 0 ] && main "$@" || exit
else
    # This script is likely sourced, not executed.
    print_warning "We detected this script is being dot sourced." \
        'If this is not intentional, either the environment variable' \
        'ARKENFOX_PREFS_CLEANER_NAME is out of sync with the name of this file' \
        'or your system is rather peculiar.'
    (exit "$init_status") && true # https://stackoverflow.com/a/53454039
fi
