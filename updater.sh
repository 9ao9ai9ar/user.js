#!/bin/sh

# arkenfox user.js updater for macOS, Linux and other Unix operating systems
# authors: @overdodactyl, @earthlng, @9ao9ai9ar
# version: 5.0

# IMPORTANT! The version string must be on the 5th line of this file
# and must be of the format "version: MAJOR.MINOR" (spaces are optional).
# This restriction is set by the function script_version.

# This ShellCheck warning is just noise for those who know what they are doing:
# "Note that A && B || C is not if-then-else. C may run when A is true."
# shellcheck disable=SC2015

# TODO: Check echo/printf usage.
# TODO: Check all relative paths as arguments to a command begin with ./.
# TODO: Check globbing is disabled before splitting on unquoted variables if globbing is not needed.
# TODO: Check all code paths where return on error is necessary and ensure proper exit status is used.
# TODO: Check these shell-aborting errors are properly handled first in a subshell:
#  1. Shell language syntax error
#  2. Special built-in utility error, including redirection error
#  3. Variable assignment error
#  4. Expansion error

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
    # The pipefail option was added in POSIX.1-2024 (SUSv5),
    # but has long been supported by most major POSIX-compatible shells,
    # with the notable exceptions of dash and ksh88-based shells.
    # There are some caveats to switching on this option though:
    # https://mywiki.wooledge.org/BashPitfalls#set_-euo_pipefail.
    # Note that we have to test in a subshell first so that
    # the non-interactive POSIX sh is not aborted by an error in set,
    # a special built-in utility:
    # https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_08_01.
    # shellcheck disable=SC3040 # In POSIX sh, set option pipefail is undefined.
    (set -o pipefail >/dev/null 2>&1) && set -o pipefail
    # To prevent the accidental insertion of SGR commands in the grep output,
    # even when not directed at a terminal, and because the --color option
    # is neither specified in POSIX nor supported by OpenBSD's grep,
    # we explicitly set the following three environment variables:
    export GREP_COLORS='mt=:ms=:mc=:sl=:cx=:fn=:ln=:bn=:se='
    export GREP_COLOR='0' # Obsolete. Use on macOS and some Unix operating systems
    :                     # where the provided grep implementations do not support GREP_COLORS.
    export GREP_OPTIONS=  # Obsolete. Use on systems with GNU grep 2.20 or earlier installed.
    while IFS='=' read -r name code; do
        # Trim trailing whitespace characters. Needed for zsh and yash.
        code=${code%"${code##*[![:space:]]}"} # https://stackoverflow.com/a/3352015
        # "When reporting the exit status with the special parameter '?',
        # the shell shall report the full eight bits of exit status available."
        # ―https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_08_02
        # "exit [n]: If n is specified, but its value is not between 0 and 255
        # inclusively, the exit status is undefined."
        # ―https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_21
        [ "$code" -ge 0 ] && [ "$code" -le 255 ] || {
            printf '%s %s\n' 'Undefined exit status in the definition:' \
                "$name=$code." >&2
            return 70 # Internal software error.
        }
        (eval readonly "$name=$code" 2>/dev/null) &&
            eval readonly "$name=$code" || {
            eval [ "\"\$$name\"" = "$code" ] &&
                continue # $name is already readonly and set to $code.
            printf '%s %s\n' "Unable to make the exit status $name readonly." \
                'Try again in a new shell environment?' >&2
            return 75 # Temp failure.
        }
    done <<EOF
$(exit_status_definitions)
EOF
    probe_environment && post_init
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
    printf '%s ' "$*" >&2
}

print_confirm() { # args: [ARGUMENT]...
    printf '%s ' "${RED}$*${RESET}" >&2
}

probe_terminal() {
    if [ -t 1 ] && [ -t 2 ] && tput setaf bold sgr0 >/dev/null 2>&1; then
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

probe_run_user() {
    if [ "$(id -u)" -eq 0 ]; then
        print_error "You shouldn't run this with elevated privileges" \
            '(such as with doas/sudo).'
        return "$EX_USAGE"
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

probe_readlink() {
    if command realpath -- . >/dev/null 2>&1; then
        __ARKENFOX_PREADLINK_IMPLEMENTATION='realpath'
    elif command readlink -f -- . >/dev/null 2>&1; then
        __ARKENFOX_PREADLINK_IMPLEMENTATION='readlink'
    elif command greadlink -f -- . >/dev/null 2>&1; then
        __ARKENFOX_PREADLINK_IMPLEMENTATION='greadlink'
    else
        print_warning 'Neither realpath nor readlink or greadlink' \
            'with support for the -f option is found on your system.' \
            'Substituting custom portable readlink implementation' \
            'for these missing utilities.'
        # Copied verbatim from https://stackoverflow.com/a/29835459.
        # FIXME: We want the behavior of realpath, not realpath -e, when sourcing.
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
    fi
    preadlink() { # args: FILE...
        if [ "$#" -le 0 ]; then
            echo 'preadlink: missing operand' >&2
            return "$EX_USAGE"
        else
            preadlink_status="$EX_OK"
            while [ "$#" -gt 0 ]; do
                case $__ARKENFOX_PREADLINK_IMPLEMENTATION in
                    'realpath')  command realpath -- "$1"     ;;
                    'readlink')  command readlink -f -- "$1"  ;;
                    'greadlink') command greadlink -f -- "$1" ;;
                    *)           rreadlink "$1"               ;;
                esac
                _status=$?
                [ "$_status" -eq "$EX_OK" ] || preadlink_status="$_status"
                shift
            done
            return "$preadlink_status"
        fi
    }
}

probe_open() {
    if command -v xdg-open >/dev/null 2>&1; then
        popen() { # args: FILE...
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
        popen() { # args: FILE...
            command open "$@"
        }
    else
        popen() {
            missing_popen
        }
    fi
}

is_option_present() { # arg: name
    [ "${1:-0}" != 0 ]
}

download_files() { # args: URL...
    # It is not easy to write portable trap commands without side effects.
    # As mktemp creates temporary files that are periodically cleared on any
    # sane system, we leave it to the OS or the user to do the cleaning
    # themselves for simplicity's sake.
    output_temp=$(mktemp) &&
        pdownloader "$output_temp" "$@" 2>/dev/null &&
        printf '%s\n' "$output_temp" || {
        print_error "Could not download $*."
        return "$EX_UNAVAILABLE"
    }
}

# TODO: Consider just printing the 5th line like in userjs_version?
script_version() { # arg: {updater.sh|prefsCleaner.sh}
    # Why not [[:digit:]] or [0-9]: https://unix.stackexchange.com/a/654391.
    # Short answer: they are locale-dependent.
    version_format='[0123456789]\{1,\}\.[0123456789]\{1,\}'
    version=$(
        sed -n "5s/.*version:[[:blank:]]*\($version_format\).*/\1/p" "$1"
    ) &&
        printf '%s\n' "$version" || {
        print_error "Could not determine script version from the file $1."
        return "$EX_DATAERR"
    }
}

###############################################################################
####                 === updater.sh specific functions ===                 ####
###############################################################################

probe_environment() {
    probe_terminal &&
        probe_run_user &&
        probe_downloader &&
        probe_mktemp &&
        probe_readlink &&
        probe_open || {
        print_error 'Encountered issues while initializing the environment.'
        return "$EX_CONFIG"
    }
}

missing_pdownloader() {
    print_error 'This script requires curl or wget on your PATH.'
    return "$EX_CNF"
}

missing_mktemp() {
    print_error 'This script requires mktemp or m4 on your PATH.'
    return "$EX_CNF"
}

missing_popen() {
    print_error 'Opening files requires xdg-open or open on your PATH.'
    return "$EX_CNF"
}

post_init() {
    # IMPORTANT! ARKENFOX_UPDATER_NAME must be synced to the name of this file!
    # This is so that we may determine if the script is sourced or not
    # by comparing it to the basename of the canonical path of $0,
    # which is better than hard coding all the names of the
    # interactive and non-interactive POSIX shells in existence.
    [ -z "$ARKENFOX_UPDATER_NAME" ] && ARKENFOX_UPDATER_NAME='updater.sh'
    arkenfox_updater_path=$(preadlink "$0") &&
        arkenfox_updater_dir=$(dirname "$arkenfox_updater_path") &&
        arkenfox_updater_name=$(basename "$arkenfox_updater_path") || {
        print_error 'An unexpected error occurred' \
            'while trying to resolve the run file path.'
        return "$EX_UNAVAILABLE"
    }
    (   
        __ARKENFOX_UPDATER_PATH=$arkenfox_updater_path &&
            __ARKENFOX_UPDATER_DIR=$arkenfox_updater_dir &&
            __ARKENFOX_UPDATER_NAME=$arkenfox_updater_name &&
            readonly __ARKENFOX_UPDATER_PATH \
                __ARKENFOX_UPDATER_DIR \
                __ARKENFOX_UPDATER_NAME
    ) >/dev/null 2>&1 &&
        __ARKENFOX_UPDATER_PATH=$arkenfox_updater_path &&
        __ARKENFOX_UPDATER_DIR=$arkenfox_updater_dir &&
        __ARKENFOX_UPDATER_NAME=$arkenfox_updater_name &&
        readonly __ARKENFOX_UPDATER_PATH \
            __ARKENFOX_UPDATER_DIR \
            __ARKENFOX_UPDATER_NAME || {
        [ "$__ARKENFOX_UPDATER_PATH" = "$arkenfox_updater_path" ] &&
            [ "$__ARKENFOX_UPDATER_DIR" = "$arkenfox_updater_dir" ] &&
            [ "$__ARKENFOX_UPDATER_NAME" = "$arkenfox_updater_name" ] || {
            print_error 'Unable to make the resolved run file path readonly.' \
                'Try again in a new shell environment?'
            return "$EX_TEMPFAIL"
        }
    }
}

main() {
    parse_options "$@" || return
    evaluate_exclusive_options || {
        status=$?
        # See comments above evaluate_exclusive_options() for an explanation.
        [ "$status" -eq "$EX__BASE" ] && return "$EX_OK" || return "$status"
    }
    show_banner
    is_option_present "$_D_DONT_UPDATE" || update_script "$@" || return
    [ -n "$PROFILE_PATH" ] || PROFILE_PATH=$(profile_path) || return
    [ -w "$PROFILE_PATH" ] && cd "$PROFILE_PATH" || {
        print_error "PROFILE_PATH '$PROFILE_PATH' needs to be a directory" \
            'where the user has both write and execute access.'
        return "$EX_UNAVAILABLE"
    }
    # TODO: What if failglob on?
    root_owned_files=$(find user.js userjs_*/ -user 0 -print)
    if [ -n "$root_owned_files" ]; then
        # \b is a backspace to keep the trailing newlines
        # from being stripped by command substitution.
        print_error 'It looks like this script was previously run' \
            'with elevated privileges.' \
            'You will need to change ownership of' \
            'the following files to your user:' \
            "$(printf '%s\n\b' '')$root_owned_files"
        return "$EX_CANTCREAT"
    fi
    update_userjs || return
}

parse_options() {
    OPTIND=1 # OPTIND must be manually reset between multiple calls to getopts.
    OPTIONS_PARSED=0
    # IMPORTANT! Make sure to initialize all options!
    _H_HELP=
    _R_READ_REMOTE_REPO_USERJS=
    _D_DONT_UPDATE=
    _U_UPDATER_SILENT=
    PROFILE_PATH=
    _L_LIST_FIREFOX_PROFILES=
    _S_SILENT=
    _C_COMPARE=
    _B_BACKUP_KEEP_LATEST_ONLY=
    _E_ESR=
    _N_NO_OVERRIDES=
    OVERRIDE=
    _V_VIEW=
    # TODO: Add -V option to display script version?
    while getopts 'hrdup:lscbeno:v' opt; do
        OPTIONS_PARSED=$((OPTIONS_PARSED + 1))
        case $opt in
            # General options
            h) _H_HELP=1 ;;
            r) _R_READ_REMOTE_REPO_USERJS=1 ;;
            # Updater options
            d) _D_DONT_UPDATE=1 ;;
            u) _U_UPDATER_SILENT=1 ;;
            # user.js options
            p) PROFILE_PATH=$OPTARG ;;
            l) _L_LIST_FIREFOX_PROFILES=1 ;;
            s) _S_SILENT=1 ;;
            c) _C_COMPARE=1 ;;
            b) _B_BACKUP_KEEP_LATEST_ONLY=1 ;;
            e) _E_ESR=1 ;;
            n) _N_NO_OVERRIDES=1 ;;
            o) OVERRIDE=$OPTARG ;;
            v) _V_VIEW=1 ;;
            \?)
                usage >&2
                return "$EX_USAGE"
                ;;
            :) return "$EX_USAGE" ;;
        esac
    done
}

usage() {
    cat <<EOF

${BLUE}Usage: $ARKENFOX_UPDATER_NAME [-h|-r]${RESET}
${BLUE}       $ARKENFOX_UPDATER_NAME [UPDATER_OPTION]... [USERJS_OPTION]...${RESET}

General options:
    -h           Show this help message and exit.
    -r           Only download user.js to a temporary file and open it.

Updater options:
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

# We want to return from the parent function as well when an exclusive option
# is present, but we have to differentiate an EX_OK status returned in this
# case from those when the option is not present, so we do a translation to
# EX__BASE, which we will revert back in the parent function.
evaluate_exclusive_options() {
    if [ "$OPTIONS_PARSED" -eq 1 ]; then
        if is_option_present "$_H_HELP"; then
            usage
            return "$EX__BASE"
        elif is_option_present "$_R_READ_REMOTE_REPO_USERJS"; then
            download_and_open_userjs && return "$EX__BASE" || return
        fi
    else
        if is_option_present "$_H_HELP" ||
            is_option_present "$_R_READ_REMOTE_REPO_USERJS"; then
            usage >&2
            return "$EX_USAGE"
        fi
    fi
}

download_and_open_userjs() {
    master_userjs=$(
        download_files \
            'https://raw.githubusercontent.com/arkenfox/user.js/master/user.js'
    ) || return
    master_userjs_fixed="$master_userjs.js"
    mv "$master_userjs" "$master_userjs_fixed" &&
        print_ok "user.js was saved to temporary file $master_userjs_fixed." &&
        popen "$master_userjs_fixed" ||
        return
}

show_banner() {
    cat <<EOF
${BBLUE}
##############################################################################
####                                                                      ####
####                           arkenfox user.js                           ####
####        Hardening the Privacy and Security Settings of Firefox        ####
####            Maintained by @Thorin-Oakenpants and @earthlng            ####
####             Updater for macOS and Linux by @overdodactyl             ####
####                                                                      ####
##############################################################################
${RESET}

Documentation for this script is available here:${CYAN}
https://github.com/arkenfox/user.js/wiki/5.1-Updater-%5BOptions%5D#-maclinux
${RESET}
EOF
}

update_script() {
    master_updater=$(
        download_files \
            'https://raw.githubusercontent.com/arkenfox/user.js/master/updater.sh'
    ) || return
    local_version=$(script_version "$__ARKENFOX_UPDATER_PATH") &&
        master_version=$(script_version "$master_updater") || return
    # TODO: Consider just doing an equality check like in prefsCleaner.sh?
    if [ "${local_version%%.*}" -eq "${master_version%%.*}" ] &&
        [ "${local_version#*.}" -lt "${master_version#*.}" ] ||
        [ "${local_version%%.*}" -lt "${master_version%%.*}" ]; then
        if ! is_option_present "$_U_UPDATER_SILENT"; then
            print_prompt 'There is a newer version of updater.sh available.'
            print_confirm 'Update and execute? [y/N]'
            read1 REPLY
            printf '\n\n\n'
            [ "$REPLY" = 'Y' ] || [ "$REPLY" = 'y' ] ||
                return "$EX_OK"
        fi
        mv -f "$master_updater" "$__ARKENFOX_UPDATER_PATH" &&
            chmod u+r+x "$__ARKENFOX_UPDATER_PATH" &&
            "$__ARKENFOX_UPDATER_PATH" -d "$@" ||
            return
    fi
}

profile_path() {
    if is_option_present "$_L_LIST_FIREFOX_PROFILES"; then
        if [ "$(uname)" = 'Darwin' ]; then # macOS
            profiles_ini="$HOME/Library/Application\ Support/Firefox/profiles.ini"
        else
            profiles_ini="$HOME/.mozilla/firefox/profiles.ini"
        fi
        [ -f "$profiles_ini" ] || {
            print_error "No profiles.ini file found at $profiles_ini."
            return "$EX_NOINPUT"
        }
        profile_path_from_ini "$profiles_ini" || return
    else
        printf '%s\n' "$__ARKENFOX_UPDATER_DIR"
    fi
}

# https://kb.mozillazine.org/Profiles.ini_file
profile_path_from_ini() { # arg: profiles.ini
    profiles_ini=$1
    selected_profile=$(select_profile "$profiles_ini") || return
    path=$(
        printf '%s\n' "$selected_profile" |
            sed -n 's/^Path=\(.*\)$/\1/p'
    )
    if [ -z "$path" ]; then
        print_error 'Failed to read the profile path in the INI file.'
        return "$EX_DATAERR"
    fi
    is_relative=$(
        printf '%s\n' "$selected_profile" |
            sed -n 's/^IsRelative=\([01]\)$/\1/p'
    )
    if [ "$is_relative" = 1 ]; then
        profiles_root_dir=$(dirname "$profiles_ini") &&
            path="${profiles_root_dir%/}/$path" || {
            print_error 'An unexpected error occurred' \
                'while converting the profile path from relative to absolute.'
            return "$EX_UNAVAILABLE"
        }
    fi
    printf '%s\n' "$path"
}

select_profile() { # arg: profiles.ini
    profile_section_regex='^[[]Profile[0123456789]{1,}[]]$'
    # https://unix.stackexchange.com/a/786827
    # shellcheck disable=SC2016 # Expressions don't expand in single quotes, use double quotes for that.
    awk_program='
        /^[[]/ {
            section = substr($0, 2)
        }

        (section ~ /^Profile[0123456789]+/) {
            print
        }
    '
    while :; do
        profiles=$(awk "$awk_program" "$1")
        [ -n "$profiles" ] || {
            print_error 'Failed to read the profile sections in the INI file.'
            return "$EX_DATAERR"
        }
        if [ "$(printf '%s' "$profiles" | grep -Ec "$profile_section_regex")" -eq 1 ]; then
            printf '%s\n' "$profiles" && return
        else
            display_profiles=$(
                printf '%s\n\n' "$profiles" |
                    grep -Ev -e '^IsRelative=' -e '^Default='
                awk '
                    /^[[]/ {
                        section = substr($0, 2)
                    }

                    ((section ~ /^Install/) && /^Default=/) {
                        print
                    }
                ' "$1"
            )
            cat >&2 <<EOF
Profiles found:
––––––––––––––––––––––––––––––
$display_profiles
––––––––––––––––––––––––––––––
EOF
            print_prompt 'Select the profile number' \
                '(0 for Profile0, 1 for Profile1, etc):'
            read -r REPLY
            printf '\n\n'
            case $REPLY in
                0 | [1-9] | [1-9][0-9]*)
                    # shellcheck disable=SC2016 # Expressions don't expand in single quotes, use double quotes for that.
                    awk_program_modified='
                        BEGIN {
                            regex = "^Profile"select"[]]"
                        }

                        /^[[]/ {
                            section = substr($0, 2)
                        }

                        section ~ regex {
                            print
                        }
                    '
                    selected_profile=$(
                        printf '%s\n' "$profiles" |
                            awk -v select="$REPLY" "$awk_program_modified"
                    ) &&
                        [ -n "$selected_profile" ] &&
                        printf '%s\n' "$selected_profile" && return ||
                        print_error 'Failed to extract configuration data' \
                            "in the Profile$REPLY section."
                    ;;
                *) print_error 'Invalid selection!' ;;
            esac
        fi
    done
}

update_userjs() {
    master_userjs=$(
        download_files \
            'https://raw.githubusercontent.com/arkenfox/user.js/master/user.js'
    ) || return
    cat <<EOF
Please observe the following information:
    Firefox profile:  ${YELLOW}$(pwd)${RESET}
    Available online: ${YELLOW}$(userjs_version "$master_userjs")${RESET}
    Currently using:  ${YELLOW}$(userjs_version user.js)${RESET}


EOF
    if ! is_option_present "$_S_SILENT"; then
        print_prompt 'This script will update to the latest user.js file' \
            'and append any custom configurations from user-overrides.js.'
        print_confirm 'Continue? [y/N]'
        read1 REPLY
        printf '\n\n'
        [ "$REPLY" = 'Y' ] || [ "$REPLY" = 'y' ] || {
            print_error 'Process aborted!'
            return "$EX_FAIL"
        }
    fi
    backup_dir='userjs_backups'
    if is_option_present "$_B_BACKUP_KEEP_LATEST_ONLY"; then
        userjs_backup="$backup_dir/user.js.backup"
    else
        userjs_backup="$backup_dir/user.js.backup.$(date '+%Y-%m-%d_%H%M')"
    fi
    # The -p option is used to suppress errors if directory exists.
    mkdir -p "$backup_dir" &&
        cp user.js "$userjs_backup" &&
        mv "$master_userjs" user.js
    print_ok 'user.js has been backed up and replaced with the latest version!'
    if is_option_present "$_E_ESR"; then
        sed -e 's/\/\* \(ESR[0-9]\{2,\}\.x still uses all.*\)/\/\/ \1/' \
            user.js >user.js.tmp &&
            mv user.js.tmp user.js
        print_ok 'ESR related preferences have been activated!'
    fi
    if ! is_option_present "$_N_NO_OVERRIDES"; then
        (   
            IFS=,
            set -f
            # shellcheck disable=SC2086
            append_overrides ${OVERRIDE:-'user-overrides.js'}
        )
    fi
    if is_option_present "$_C_COMPARE"; then
        diff_dir='userjs_diffs'
        old_userjs_stripped=$(mktemp)
        new_userjs_stripped=$(mktemp)
        # TODO: Include old and new user.js version + ESR info in the filename?
        diff_file="$diff_dir/diff_$(date +"%Y-%m-%d_%H%M").txt"
        mkdir -p "$diff_dir" &&
            remove_comments "$userjs_backup" >"$old_userjs_stripped" &&
            remove_comments user.js >"$new_userjs_stripped"
        diff=$(diff -b -U 0 "$old_userjs_stripped" "$new_userjs_stripped")
        if [ -n "$diff" ]; then
            printf '%s\n' "$diff" >"$diff_file"
            print_ok "A diff file was created: $PWD/$diff_file."
        else
            print_warning 'Your new user.js file appears to be identical.' \
                'No diff file was created.'
            ! is_option_present "$_B_BACKUP_KEEP_LATEST_ONLY" &&
                rm "$userjs_backup"
        fi
    fi
    is_option_present "$_V_VIEW" && popen user.js
}

userjs_version() { # arg: user.js
    [ -f "$1" ] && sed -n '4p' "$1" || echo 'Unknown'
}

append_overrides() { # args: FILE...
    unset IFS
    set +f
    while [ "$#" -gt 0 ]; do
        if [ -f "$1" ]; then
            echo >>user.js
            cat "$1" >>user.js
            print_ok "Override file appended: $1."
        elif [ -d "$1" ]; then
            for f in ./"$1"/*.js; do
                [ "$f" = "./$1/*.js" ] && break # Custom failglob on.
                append_overrides "$f"
            done
        else
            print_warning "Could not find override file: $1."
        fi
        shift
    done
}

remove_comments() { # arg: FILE
    # Copied verbatim from the public domain sed script at
    # https://sed.sourceforge.io/grabbag/scripts/remccoms3.sed.
    # The best POSIX solution on the internet, though it does not handle files
    # with syntax errors in C as well as emacs does, e.g.
    : Unterminated multi-line strings test case <<'EOF'
/* "not/here
*/"//"
// non "here /*
should/appear
// \
nothere
should/appear
"a \" string with embedded comment /* // " /*nothere*/
"multiline
/*string" /**/ shouldappear //*nothere*/
/*/ nothere*/ should appear
EOF
    # The reference output is given by:
    # cpp -P -std=c99 -fpreprocessed -undef -dD "$1"
    # The options "-Werror -Wfatal-errors" may be added to better mimick
    # Firefox's parsing of user.js.
    remccoms3=$(
        cat <<'EOF'
#! /bin/sed -nf

# Remove C and C++ comments, by Brian Hiles (brian_hiles@rocketmail.com)

# Sped up (and bugfixed to some extent) by Paolo Bonzini (bonzini@gnu.org)
# Works its way through the line, copying to hold space the text up to the
# first special character (/, ", ').  The original version went exactly a
# character at a time, hence the greater speed of this one.  But the concept
# and especially the trick of building the line in hold space are entirely
# merit of Brian.

:loop

# This line is sufficient to remove C++ comments!
/^\/\// s,.*,,

/^$/{
  x
  p
  n
  b loop
}
/^"/{
  :double
  /^$/{
    x
    p
    n
    /^"/b break
    b double
  }

  H
  x
  s,\n\(.[^\"]*\).*,\1,
  x
  s,.[^\"]*,,

  /^"/b break
  /^\\/{
    H
    x
    s,\n\(.\).*,\1,
    x
    s/.//
  }
  b double
}

/^'/{
  :single
  /^$/{
    x
    p
    n
    /^'/b break
    b single
  }
  H
  x
  s,\n\(.[^\']*\).*,\1,
  x
  s,.[^\']*,,

  /^'/b break
  /^\\/{
    H
    x
    s,\n\(.\).*,\1,
    x
    s/.//
  }
  b single
}

/^\/\*/{
  s/.//
  :ccom
  s,^.[^*]*,,
  /^$/ n
  /^\*\//{
    s/..//
    b loop
  }
  b ccom
}

:break
H
x
s,\n\(.[^"'/]*\).*,\1,
x
s/.[^"'/]*//
b loop
EOF
    )
    # Add LC_ALL=C to prevent indefinite loop in some cases:
    # https://stackoverflow.com/q/13061785/#comment93013794_13062074.
    LC_ALL=C sed -ne "$remccoms3" "$1" |
        sed '/^[[:space:]]*$/d' # Remove blank lines.
}

init
init_status=$?
if [ "$init_status" -eq 0 ]; then
    if [ "$__ARKENFOX_UPDATER_NAME" = "$ARKENFOX_UPDATER_NAME" ]; then
        main "$@"
    else
        print_ok 'The arkenfox updater script has been successfully sourced.'
        print_warning 'If this is not intentional,' \
            'you may have either made a typo in the shell commands,' \
            'or renamed this file without defining the environment variable' \
            'ARKENFOX_UPDATER_NAME to match the new name.' \
            "

         Detected name of the run file: $__ARKENFOX_UPDATER_NAME
         ARKENFOX_UPDATER_NAME: $ARKENFOX_UPDATER_NAME
        
        " \
            'Note that this is not the expected way' \
            'to run the arkenfox updater script.' \
            'Dot sourcing support is experimental' \
            'and only provided for convenience.'
    fi
else
    (exit "$init_status") && true # https://stackoverflow.com/a/53454039
fi
