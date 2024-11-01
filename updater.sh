#!/bin/sh

# arkenfox user.js updater for macOS, Linux and other Unix operating systems
# authors: @overdodactyl, @earthlng, @9ao9ai9ar
# version: 5.0

# shellcheck disable=SC2015
# SC2015: Note that A && B || C is not if-then-else. C may run when A is true.
# This is just noise for those who know what they are doing.

# IMPORTANT! The version string must be between the 2nd and 10th lines,
# inclusive, of this file, and must be of the format "version: MAJOR.MINOR"
# (spaces after the colon are optional).

# IMPORTANT! ARKENFOX_UPDATER_NAME must be synced to the name of this file!
# This is so that we may determine if the script is sourced or not by
# comparing it to the basename of the canonical path of $0.
[ -z "$ARKENFOX_UPDATER_NAME" ] && readonly ARKENFOX_UPDATER_NAME='updater.sh'

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
####                 === updater.sh specific functions ===                 ####
###############################################################################

probe_environment() {
    probe_terminal &&
        probe_run_user &&
        probe_readlink &&
        probe_mktemp &&
        probe_downloader &&
        probe_open || {
        print_error 'Encountered issues while initializing the environment.'
        return "$EX_CONFIG"
    }
}

missing_mktemp() {
    print_error 'This script requires mktemp or m4 on your PATH.'
    return "$EX_CNF"
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
    parse_options "$@" || return
    execute_exclusive_options
    status=$?
    # See comments above execute_exclusive_options() for explanation.
    [ "$status" -eq "$EX__BASE" ] && return "$EX_OK" || return "$status"
    show_banner
    if ! is_option_present "$_D_DONT_UPDATE"; then
        update_script "$@" || return
    fi
    [ -d "$PROFILE_PATH" ] || PROFILE_PATH=$(set_profile_path)
    # We need u+w+x permissions to PROFILE_PATH.
    cd "$PROFILE_PATH" || return
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
    update_userjs
}

default_options() {
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
}

parse_options() {
    default_options
    OPTIONS_PARSED=0
    OPTIND=1 # IMPORTANT! https://stackoverflow.com/q/5048326
    while getopts 'hrdup:lscbeno:v' opt; do
        OPTIONS_PARSED=$((OPTIONS_PARSED + 1))
        case $opt in
            h) _H_HELP=1 ;;
            r) _R_READ_REMOTE_REPO_USERJS=1 ;;
            d) _D_DONT_UPDATE=1 ;;
            u) _U_UPDATER_SILENT=1 ;;
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

# TODO: Add -V option to display script version?
usage() {
    cat <<EOF

${BLUE}Usage: $ARKENFOX_UPDATER_NAME [-h|-r]${RESET}
${BLUE}       $ARKENFOX_UPDATER_NAME [UPDATER_OPTION]... [USERJS_OPTION]...${RESET}

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

# https://stackoverflow.com/q/58103370
# We want to return from the parent function as well when an exclusive option
# is present, but we have to differentiate an EX_OK status returned in this
# case from those when the options are not present, so we do a translation to
# EX__BASE, which we will revert back to EX_OK in the parent function.
execute_exclusive_options() {
    if [ "$OPTIONS_PARSED" -eq 1 ]; then
        if is_option_present "$_H_HELP"; then
            usage
            return "$EX__BASE"
        elif is_option_present "$_R_READ_REMOTE_REPO_USERJS"; then
            if download_and_open_userjs; then
                return "$EX__BASE"
            else
                return
            fi
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
    mv "$master_userjs" "$master_userjs.js"
    print_warning "user.js was saved to temporary file $master_userjs.js."
    popen "$master_userjs.js"
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

Documentation for this script is available here:
${CYAN}https://github.com/arkenfox/user.js/wiki/5.1-Updater-%5BOptions%5D#-maclinux${RESET}

EOF
}

update_script() {
    master_updater=$(
        download_files \
            'https://raw.githubusercontent.com/arkenfox/user.js/master/updater.sh'
    ) || return
    local_version=$(script_version "$SCRIPT_PATH") &&
        master_version=$(script_version "$master_updater") || return
    # TODO: Consider just printing the 5th line and do a simple equality check
    #  like is done in userjs_version and prefsCleaner.sh, respectively?
    if [ "${local_version%%.*}" -eq "${master_version%%.*}" ] &&
        [ "${local_version#*.}" -lt "${master_version#*.}" ] ||
        [ "${local_version%%.*}" -lt "${master_version%%.*}" ]; then # Update available.
        if ! is_option_present "$_U_UPDATER_SILENT"; then
            print_prompt 'There is a newer version of updater.sh available.'
            print_confirm 'Update and execute Y/N?'
            read1 REPLY
            printf '\n\n\n'
            [ "$REPLY" = 'Y' ] || [ "$REPLY" = 'y' ] || return "$EX_OK" # User chooses not to update.
        fi
        mv "$master_updater" "$SCRIPT_PATH" &&
            chmod u+r+x "$SCRIPT_PATH" &&
            "$SCRIPT_PATH" -d "$@"
    fi
}

set_profile_path() {
    if is_option_present "$_L_LIST_FIREFOX_PROFILES"; then
        if [ "$(uname)" = 'Darwin' ]; then
            profiles_ini="$HOME/Library/Application\ Support/Firefox/profiles.ini"
        else
            profiles_ini="$HOME/.mozilla/firefox/profiles.ini"
        fi
        [ -f "$profiles_ini" ] || {
            # TODO: Reword error message?
            print_error 'Sorry, -l is not supported for your OS.'
            return "$EX_NOINPUT"
        }
        read_profilesini "$profiles_ini" || return
    else
        printf '%s\n' "$SCRIPT_DIR"
    fi
}

read_profilesini() { # arg: profiles.ini
    profiles_ini=$1
    # profile_configs will contain:
    # [ProfileN], Name=, IsRelative= and Path= (and Default= if present).
    profile_configs=$(
        awk '/^[[]Profile[0123456789]{1,}[]]$|Default=[^1]/{
                 if (p == 1) print "";
                 p = 1;
                 print;
             }
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
                selected_profile_config=$(
                    grep -A 4 "^\[Profile${REPLY}" "$profiles_ini"
                ) || {
                    print_error "Profile${REPLY} does not exist!"
                    return "$EX_NOINPUT"
                }
                ;;
            *)
                # FIXME: Wrong selection should loop over instead of quitting.
                print_error 'Invalid selection!'
                return "$EX_FAIL"
                ;;
        esac
    fi
    # Extracting 0 or 1 from the "IsRelative=" line.
    is_relative=$(printf '%s\n' "$selected_profile_config" |
        sed -n 's/^IsRelative=\([01]\)$/\1/p')
    # Extracting only the path itself, excluding "Path=".
    path=$(printf '%s\n' "$selected_profile_config" |
        sed -n 's/^Path=\(.*\)$/\1/p')
    # Update global variable if path is relative.
    [ "$is_relative" = '1' ] && path="$(dirname "$profiles_ini")/$path"
    printf '%s\n' "$path"
}

# Applies latest version of user.js and any custom overrides.
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
        print_confirm 'Continue Y/N?'
        read1 REPLY
        printf '\n\n'
        [ "$REPLY" = 'Y' ] || [ "$REPLY" = 'y' ] || {
            print_error 'Process aborted!'
            return "$EX_FAIL"
        }
    fi
    # Copy a version of user.js to diffs folder for later comparison.
    if is_option_present "$_C_COMPARE"; then
        mkdir -p userjs_diffs
        cp user.js userjs_diffs/past_user.js >/dev/null 2>&1
    fi
    # Backup user.js.
    mkdir -p userjs_backups
    bakname="userjs_backups/user.js.backup.$(date +"%Y-%m-%d_%H%M")"
    is_option_present "$_B_BACKUP_KEEP_LATEST_ONLY" &&
        bakname='userjs_backups/user.js.backup'
    cp user.js "$bakname" >/dev/null 2>&1
    mv "$master_userjs" user.js
    print_ok 'user.js has been backed up and replaced with the latest version!'
    if is_option_present "$_E_ESR"; then
        sed -e 's/\/\* \(ESR[0-9]\{2,\}\.x still uses all.*\)/\/\/ \1/' \
            user.js >user.js.tmp &&
            mv user.js.tmp user.js
        print_ok 'ESR related preferences have been activated!'
    fi
    # Apply overrides.
    if ! is_option_present "$_N_NO_OVERRIDES"; then
        #        printf '%s\n' "$OVERRIDE" |
        #            while IFS=',' read -r FILE; do
        #                add_override "$FILE"
        #            done
        (
            IFS=,
            for FILE in ${OVERRIDE:-'./user-overrides.js'}; do
                add_override "$FILE"
            done
        )
    fi
    # Create diff.
    if is_option_present "$_C_COMPARE"; then
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
            print_warning 'Your new user.js file appears to be identical.' \
                'No diff file was created.'
            ! is_option_present "$_B_BACKUP_KEEP_LATEST_ONLY" &&
                rm "$bakname" >/dev/null 2>&1
        fi
        rm "$past_nocomments" "$current_nocomments" "$pastuserjs" >/dev/null 2>&1
    fi
    is_option_present "$_V_VIEW" && popen "$PWD/user.js"
}

userjs_version() {
    [ -f "$1" ] && sed -n '4p' "$1" || echo 'Not detected.'
}

add_override() {
    unset IFS
    input=$1
    if [ -f "$input" ]; then
        echo >>user.js
        cat "$input" >>user.js
        print_ok "Override file appended: $input."
    elif [ -d "$input" ]; then
        # \b is a backspace to keep the trailing newlines
        # from being stripped by command substitution.
        # Any other non-newline character should do it, but it is the safest.
        IFS=$(printf '\n\b')
        for f in ./"$input"/*.js; do
            [ "$f" = "./$input/*.js" ] && break # Custom failglob on.
            add_override "$f"
        done
    else
        print_warning "Could not find override file: $input."
    fi
}

# https://github.com/arkenfox/user.js/commit/ada31d4f504d666530c038d9cf75fcfbb940ba67:
# Fix the issue that "All prefs after a multi-line comment declaration, on a
# single line, are deleted with the remove_comments function from the updater."
# https://github.com/arkenfox/user.js/commit/6968b9a369c30f912195e56c132f6357c00ba8e8:
# Re-arrange the match patterns to fix the remaining issue
# of dropping lines after the 9999 block.
remove_comments() { # expects 2 arguments: from-file and to-file.
    sed -e '/^\/\*.*\*\/[[:space:]]*$/d' \
        -e '/^\/\*/,/\*\//d' \
        -e 's|^[[:space:]]*//.*$||' \
        -e '/^[[:space:]]*$/d' \
        -e 's|);[[:space:]]*//.*|);|' "$1" >"$2"
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
if [ "$SCRIPT_NAME" = "$ARKENFOX_UPDATER_NAME" ]; then
    # This script is likely executed, not sourced.
    [ "$init_status" -eq 0 ] && main "$@" || exit
else
    # This script is likely sourced, not executed.
    print_warning "We detected this script is being dot sourced." \
        'If this is not intentional, either the environment variable' \
        'ARKENFOX_UPDATER_NAME is out of sync with the name of this file' \
        'or your system is rather peculiar.'
    (exit "$init_status") && true # https://stackoverflow.com/a/53454039
fi
