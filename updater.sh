#!/bin/sh

# arkenfox user.js updater for macOS and Linux
# authors: @overdodactyl, @earthlng, @ema-pe, @claustromaniac, @infinitewarp, @9ao9ai9ar
# version: 4.1

# shellcheck disable=SC2015
# SC2015: Note that A && B || C is not if-then-else. C may run when A is true.
# This is just noise for those who know what they are doing.

# IMPORTANT! ARKENFOX_UPDATER_NAME must be in sync with the name of
# the arkenfox user.js updater script for macOS and Linux (this file).
# We do not parameterize ARKENFOX_UPDATER_NAME to $0 because we need to compare
# its value to the basename value of $0 to determine if the script is sourced
# or not, and because ARKENFOX_UPDATER_NAME should rarely need to be changed.
ARKENFOX_UPDATER_NAME='updater.sh'
#ARKENFOX_UPDATER_VERSION='4.1'

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

probe_open() {
    popen() { # args: FILE...
        missing_popen
    }
    if command -v xdg-open >/dev/null 2>&1; then
        popen() {
            if [ "$#" -le 0 ]; then
                command xdg-open
            else
                while [ "$#" -gt 0 ]; do
                    command xdg-open "$1"
                    shift
                done
            fi
        }
    elif command -v open >/dev/null 2>&1; then
        popen() {
            command open "$@"
        }
    else
        : # TODO: open in Firefox?
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

# Copied verbatim from https://unix.stackexchange.com/a/464963.
read1() { # arg: <variable-name>
    if [ -t 0 ]; then
        # if stdin is a tty device, put it out of icanon, set min and
        # time to sane value, but don't otherwise touch other input or
        # or local settings (echo, isig, icrnl...). Take a backup of the
        # previous settings beforehand.
        saved_tty_settings=$(stty -g)
        stty -icanon min 1 time 0
    fi
    eval "$1="
    while
        # read one byte, using a work around for the fact that command
        # substitution strips trailing newline characters.
        c=$(
            dd bs=1 count=1 2>/dev/null
            echo .
        )
        c=${c%.}

        # break out of the loop on empty input (eof) or if a full character
        # has been accumulated in the output variable (using "wc -m" to count
        # the number of characters).
        [ -n "$c" ] &&
            eval "$1=\${$1}"'$c
        [ "$(($(printf %s "${'"$1"'}" | wc -m)))" -eq 0 ]'
    do
        continue
    done
    if [ -t 0 ]; then
        # restore settings saved earlier if stdin is a tty device.
        stty "$saved_tty_settings"
    fi
}

###################################
## updater.sh specific functions ##
###################################

probe_environment() {
    probe_terminal &&
        probe_permissions &&
        probe_readlink &&
        probe_mktemp &&
        probe_downloader &&
        probe_open || {
        print_error 'Encountered issues while trying to initialize the environment.'
        return "$EX_CONFIG"
    }
}

missing_pdownloader() {
    print_error 'This script requires curl or wget on your PATH.'
    return "$EX_CNF"
}

missing_popen() {
    print_error 'Opening files requires xdg-open or open on your PATH.'
    return "$EX_CNF"
}

main() {
    show_banner
    # Set ARKENFOX_UPDATER_PATH to the path of the arkenfox user.js updater for
    # macOS and Linux if it is not at the root of the run directory.
    if [ -z "$ARKENFOX_UPDATER_PATH" ]; then
        [ -f "./$ARKENFOX_UPDATER_NAME" ] &&
            [ -x "./$ARKENFOX_UPDATER_NAME" ] &&
            ARKENFOX_UPDATER_PATH=$(preadlink "./$ARKENFOX_UPDATER_NAME") ||
            return
    else
        [ -f "$ARKENFOX_UPDATER_PATH" ] &&
            [ -x "$ARKENFOX_UPDATER_PATH" ] ||
            return
    fi
    # shellcheck disable=SC2046
    eval $(parse_options "$@") &&
        eval export $(option_definitions | cut -d'=' -f1) ||
        return
    if is_set "${_H_HELP}"; then
        [ "$n_parsed_options" -eq 1 ] &&
            usage &&
            return ||
            return
    fi
    echo "${_R_READ_REMOTE_REPO_USERJS}"
    if is_set "${_R_READ_REMOTE_REPO_USERJS}"; then
        [ "$n_parsed_options" -eq 1 ] &&
            download_and_open_userjs &&
            return ||
            return
    fi
    ! is_set "${_D_DONT_UPDATE}" && update_script "$@"
    [ -d "$PROFILE_PATH" ] &&
        [ -x "$PROFILE_PATH" ] &&
        [ -w "$PROFILE_PATH" ] || PROFILE_PATH=$(set_profile_path)
    cd "$PROFILE_PATH" || return
    probe_permissions || return
    update_userjs
}

show_banner() {
    cat <<EOF
${BBLUE}
                ############################################################################
                ####                                                                    ####
                ####                          arkenfox user.js                          ####
                ####       Hardening the Privacy and Security Settings of Firefox       ####
                ####           Maintained by @Thorin-Oakenpants and @earthlng           ####
                ####            Updater for macOS and Linux by @overdodactyl            ####
                ####                                                                    ####
                ############################################################################
${RESET}

Documentation for this script is available here: ${CYAN}https://github.com/arkenfox/user.js/wiki/5.1-Updater-%5BOptions%5D#-maclinux${RESET}

EOF
}

option_definitions() {
    cat <<EOF
_H_HELP=
_R_READ_REMOTE_REPO_USERJS=
_D_DONT_UPDATE=
_U_UPDATER_SILENT=
PROFILE_PATH=$ARKENFOX_UPDATER_PATH
_L_LIST_FIREFOX_PROFILES=
_S_SILENT=
_C_COMPARE=
_B_BACKUP_KEEP_LATEST_ONLY=
_E_ESR=
_N_NO_OVERRIDES=
OVERRIDE='./user-overrides.js'
_V_VIEW=
EOF
}

parse_options() {
    n_parsed_options=0
    # shellcheck disable=SC2046
    eval $(option_definitions) &&
        while getopts 'hrdup:lscbeno:v' opt; do
            n_parsed_options=$((n_parsed_options + 1))
            case $opt in
                h)
                    l=_H_HELP=1
                    ;;
                r)
                    l=_R_READ_REMOTE_REPO_USERJS=1
                    ;;
                d)
                    l=_D_DONT_UPDATE=1
                    ;;
                u)
                    l=_U_UPDATER_SILENT=1
                    ;;
                p)
                    l=PROFILE_PATH=$OPTARG
                    ;;
                l)
                    l=_L_LIST_FIREFOX_PROFILES=1
                    ;;
                s)
                    l=_S_SILENT=1
                    ;;
                c)
                    l=_C_COMPARE=1
                    ;;
                b)
                    l=_B_BACKUP_KEEP_LATEST_ONLY=1
                    ;;
                e)
                    l=_E_ESR=1
                    ;;
                n)
                    l=_N_NO_OVERRIDES=1
                    ;;
                o)
                    l=OVERRIDE=$OPTARG
                    ;;
                v)
                    l=_V_VIEW=1
                    ;;
                \?)
                    usage >&2
                    return "$EX_USAGE"
                    ;;
                :)
                    return "$EX_USAGE"
                    ;;
            esac
            printf '%s\n' "$l"
        done &&
        printf '%s\n' "n_parsed_options=$n_parsed_options" ||
        {
            print_error 'An unexpected error occurred while evaluating option definitions.'
            return "$EX_UNAVAILABLE"
        }
}

usage() {
    cat <<EOF

${BLUE}Usage: $ARKENFOX_UPDATER_NAME [-h|-r]
              $ARKENFOX_UPDATER_NAME [UPDATER_OPTION]... [USERJS_OPTION]...${RESET}

General options:
    -h           Show this help message and exit.
    -r           Only download user.js to a temporary file and open it.

updater.sh options:
    -d           Do not look for updates to updater.sh.
    -u           Update updater.sh and execute silently.  Do not seek confirmation.

user.js options:
    -p PROFILE   Path to your Firefox profile (if different than the dir of this script).
                 IMPORTANT: If the path contains spaces, wrap the entire argument in quotes.
    -l           Choose your Firefox profile from a list.
    -s           Silently update user.js.  Do not seek confirmation.
    -c           Create a diff file comparing old and new user.js within userjs_diffs.
    -b           Only keep one backup of each file.
    -e           Activate ESR related preferences.
    -n           Do not append any overrides, even if user-overrides.js exists.
    -o OVERRIDE  Filename or path to overrides file (if different than user-overrides.js).
                 If used with -p, paths should be relative to PROFILE or absolute paths.
                 If given a directory, all files inside will be appended recursively.
                 You can pass multiple files or directories by passing a comma separated list.
                 Note: If a directory is given, only files inside ending in the extension .js are appended.
                 IMPORTANT: Do not add spaces between files/paths.  Ex: -o file1.js,file2.js,dir1
                 IMPORTANT: If any file/path contains spaces, wrap the entire argument in quotes.  Ex: -o "override folder"
    -v           Open the resulting user.js file.

EOF
}

download_and_open_userjs() {
    master_userjs=$(
        download_files 'https://raw.githubusercontent.com/arkenfox/user.js/master/user.js'
    ) || return
    mv "$master_userjs" "$master_userjs.js"
    print_warning "user.js was saved to temporary file $master_userjs.js."
    popen "$master_userjs.js"
}

update_script() {
    master_updater=$(
        download_files 'https://raw.githubusercontent.com/arkenfox/user.js/master/updater.sh'
    ) || return
    local_version=$(script_version "$ARKENFOX_UPDATER_PATH") &&
        master_version=$(script_version "$master_updater") || return
    if [ "${local_version%%.*}" -eq "${master_version%%.*}" ] &&
        [ "${local_version#*.}" -lt "${master_version#*.}" ] ||
        [ "${local_version%%.*}" -lt "${master_version%%.*}" ]; then # Update available.
        if ! is_set "${_U_UPDATER_SILENT}"; then
            print_prompt 'There is a newer version of updater.sh available.'
            print_confirm 'Update and execute Y/N?'
            read1 REPLY
            printf '\n\n\n'
            [ "$REPLY" = 'Y' ] || [ "$REPLY" = 'y' ] || return "$EX_OK" # User chooses not to update.
        fi
        mv "$master_updater" "$ARKENFOX_UPDATER_PATH" &&
            chmod u+r+x "$ARKENFOX_UPDATER_PATH" &&
            "$ARKENFOX_UPDATER_PATH" -d "$@"
    fi
}

set_profile_path() {
    if is_set "${_L_LIST_FIREFOX_PROFILES}"; then
        if [ "$(uname)" = 'Darwin' ]; then
            profiles_ini="$HOME/Library/Application\ Support/Firefox/profiles.ini"
        else
            profiles_ini="$HOME/.mozilla/firefox/profiles.ini"
        fi
        [ -f "$profiles_ini" ] &&
            [ -r "$profiles_ini" ] || {
            # FIXME: reword profiles.ini related error messages.
            print_error 'Sorry, -l is not supported for your OS.'
            return "$EX_NOINPUT"
        }
        read_profilesini "$profiles_ini" || return
    else
        printf '%s\n' "$(dirname "$ARKENFOX_UPDATER_PATH")"
    fi
}

read_profilesini() { # arg: profiles.ini
    profiles_ini=$1
    # profile_configs will contain: [ProfileN], Name=, IsRelative= and Path= (and Default= if present).
    profile_configs=$(
        awk '/^[[]Profile[0123456789]{1,}[]]$|Default=[^1]/{ if (p == 1) print ""; p = 1; print; }
             /Name=|IsRelative=|Path=/{ print; }' "$profiles_ini"
    )
    if [ "$(grep -Ec '^[[]Profile[0123456789]{1,}[]]$' "$profiles_ini")" -eq 1 ]; then
        selected_profile_config="$profile_configs"
    else
        cat <<EOF
Profiles found:
––––––––––––––––––––––––––––––
$profile_configs
––––––––––––––––––––––––––––––
Select the profile number ( 0 for Profile0, 1 for Profile1, etc ) :
EOF
        read -r REPLY
        printf '\n\n'
        case $REPLY in
            0 | [1-9] | [1-9][0-9]*)
                selected_profile_config=$(grep -A 4 "^\[Profile${REPLY}" "$profiles_ini") || {
                    print_error "Profile${REPLY} does not exist!"
                    return "$EX_NOINPUT"
                }
                ;;
            *)
                # FIXME: wrong selection should loop the prompt instead of quitting.
                print_error 'Invalid selection!'
                return "$EX_FAIL"
                ;;
        esac
    fi
    # extracting 0 or 1 from the "IsRelative=" line
    is_relative=$(printf '%s\n' "$selected_profile_config" | sed -n 's/^IsRelative=\([01]\)$/\1/p')
    # extracting only the path itself, excluding "Path="
    path=$(printf '%s\n' "$selected_profile_config" | sed -n 's/^Path=\(.*\)$/\1/p')
    # update global variable if path is relative
    [ "$is_relative" = '1' ] && path="$(dirname "$profiles_ini")/$path"
    printf '%s\n' "$path"
}

# Applies latest version of user.js and any custom overrides.
update_userjs() {
    master_userjs=$(
        download_files 'https://raw.githubusercontent.com/arkenfox/user.js/master/user.js'
    ) || return
    cat <<EOF
Please observe the following information:
    Firefox profile:  ${YELLOW}$(pwd)${RESET}
    Available online: ${YELLOW}$(userjs_version "$master_userjs")${RESET}
    Currently using:  ${YELLOW}$(userjs_version user.js)${RESET}


EOF
    if ! is_set "${_S_SILENT}"; then
        print_prompt 'This script will update to the latest user.js file' \
            'and append any custom configurations from user-overrides.js.'
        print_confirm 'Continue Y/N?'
        read1 REPLY
        printf '\n\n'
        [ "$REPLY" = 'Y' ] || [ "$REPLY" = 'y' ] || {
            print_error 'Process aborted!'
            return "$EX_FAIL"
        }
    fi
    # Copy a version of user.js to diffs folder for later comparison.
    if is_set "${_C_COMPARE}"; then
        mkdir -p userjs_diffs
        cp user.js userjs_diffs/past_user.js >/dev/null 2>&1
    fi
    # Backup user.js.
    mkdir -p userjs_backups
    bakname="userjs_backups/user.js.backup.$(date +"%Y-%m-%d_%H%M")"
    is_set "${_B_BACKUP_KEEP_LATEST_ONLY}" && bakname='userjs_backups/user.js.backup'
    cp user.js "$bakname" >/dev/null 2>&1
    mv "$master_userjs" user.js
    print_ok 'user.js has been backed up and replaced with the latest version!'
    if is_set "${_E_ESR}"; then
        sed -e 's/\/\* \(ESR[0-9]\{2,\}\.x still uses all.*\)/\/\/ \1/' user.js >user.js.tmp &&
            mv user.js.tmp user.js
        print_ok 'ESR related preferences have been activated!'
    fi
    # Apply overrides.
    if ! is_set "${_N_NO_OVERRIDES}"; then
        (
            IFS=,
            for FILE in $OVERRIDE; do
                add_override "$FILE"
            done
        )
    fi
    # Create diff.
    if is_set "${_C_COMPARE}"; then
        pastuserjs='userjs_diffs/past_user.js'
        past_nocomments='userjs_diffs/past_userjs.txt'
        current_nocomments='userjs_diffs/current_userjs.txt'
        remove_comments "$pastuserjs" "$past_nocomments"
        remove_comments user.js "$current_nocomments"
        diffname="userjs_diffs/diff_$(date +"%Y-%m-%d_%H%M").txt"
        diff=$(diff -w -B -U 0 "$past_nocomments" "$current_nocomments")
        if [ -n "$diff" ]; then
            printf '%s\n' "$diff" >"$diffname"
            print_ok "A diff file was created: $PWD/$diffname."
        else
            print_warning 'Your new user.js file appears to be identical. No diff file was created.'
            ! is_set "${_B_BACKUP_KEEP_LATEST_ONLY}" && rm "$bakname" >/dev/null 2>&1
        fi
        rm "$past_nocomments" "$current_nocomments" "$pastuserjs" >/dev/null 2>&1
    fi
    is_set "${_V_VIEW}" && popen "$PWD/user.js"
}

userjs_version() {
    [ -e "$1" ] && sed -n '4p' "$1" || echo 'Not detected.'
}

add_override() {
    unset IFS
    input=$1
    if [ -f "$input" ]; then
        echo >>user.js
        cat "$input" >>user.js
        print_ok "Override file appended: $input."
    elif [ -d "$input" ]; then
        # FIXME: Word boundaries regexes are not portable.
        # https://lists.gnu.org/archive/html/autoconf-patches/2016-10/msg00000.html
        # macOS and BSD: [[:<:]], [[:>:]].
        # Linux and Solaris: \<, \>.
        # \b is GNU only.
        IFS=$(printf '\n\b')
        for f in ./"$input"/*.js; do
            [ "$f" = "./$input/*.js" ] && break # custom failglob on
            add_override "$f"
        done
    else
        print_warning "Could not find override file: $input."
    fi
}

remove_comments() { # expects 2 arguments: from-file and to-file
    sed -e '/^\/\*.*\*\/[[:space:]]*$/d' \
        -e '/^\/\*/,/\*\//d' \
        -e 's|^[[:space:]]*//.*$||' \
        -e '/^[[:space:]]*$/d' \
        -e 's|);[[:space:]]*//.*|);|' "$1" >"$2"
}

init && unset -f init # Unset init to mitigate the double init problem.
init_status=$?
if [ "$(basename "$0")" = "$ARKENFOX_UPDATER_NAME" ]; then # This script is executed, not sourced.
    main "$@"
else
    (exit "$init_status") && true # https://stackoverflow.com/a/53454039
fi
