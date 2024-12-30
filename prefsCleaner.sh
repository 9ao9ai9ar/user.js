#!/bin/sh

# prefs.js cleaner for macOS, Linux and Unix-like operating systems
# authors: @claustromaniac, @earthlng, @9ao9ai9ar
# version: 3.0

# IMPORTANT! The version string must be on the 5th line of this file
# and must be of the format "version: MAJOR.MINOR" (spaces are optional).
# This restriction is set by the function arkenfox_script_version.

# Example advanced script usage:
# $ yes | env PROBE_MISSING=1 ./prefsCleaner.sh >/dev/null 2>&1
# $ TERM=dumb WGET__IMPLEMENTATION=wget . ./prefsCleaner.sh && arkenfox_prefs_cleaner

# This ShellCheck warning is just noise for those who know what they are doing:
# "Note that A && B || C is not if-then-else. C may run when A is true."
# shellcheck disable=SC2015

###############################################################################
####                   === Common utility functions ===                    ####
#### Code that is shared between updater.sh and prefsCleaner.sh, inlined   ####
#### and duplicated only to maintain the same file count as before.        ####
###############################################################################

# Save the starting sh options for later restoration.
# Copied from https://unix.stackexchange.com/a/383581.
_ARKENFOX_STARTING_SHOPTS=$(\set +o) || \return 2>/dev/null || \exit
case $- in
    *e*) _ARKENFOX_STARTING_SHOPTS="$_ARKENFOX_STARTING_SHOPTS; set -e" ;;
    *) _ARKENFOX_STARTING_SHOPTS="$_ARKENFOX_STARTING_SHOPTS; set +e" ;;
esac
# Additionally, detect spoofing by external, readonly functions.
\set -e || \return 2>/dev/null || \exit
\export LC_ALL=C
# Ensure no function of the same name is invoked before unalias the utility
# (see https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_09_01_01),
\unset -f unalias
# which must be run asap because alias substitution occurs right before parsing:
# https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_03_01.
\unalias -a

download_file() { # arg: URL
    # The try-finally construct can be implemented as a series of trap commands.
    # However, it is notoriously difficult to write them portably and reliably.
    # Since mktemp_ creates temporary files that are periodically cleared
    # on any sane system, we leave it to the OS or the user to do the cleaning
    # themselves for simplicity's sake.
    output_temp=$(mktemp_) &&
        wget_ "$output_temp" "$1" >/dev/null 2>&1 &&
        printf '%s\n' "$output_temp" || {
        print_error "Failed to download file from the URL: $1."
        return "${_EX_UNAVAILABLE:?}"
    }
}

# Improved on the "secure shell script" example demonstrated in
# https://pubs.opengroup.org/onlinepubs/9699919799/utilities/command.html#tag_20_22_17.
init() {
    # To prevent the accidental insertion of SGR commands in the grep output,
    # even when not directed at a terminal, we explicitly set the three
    # GREP_* environment variables:
    \export LC_ALL=C GREP_COLORS='mt=:ms=:mc=:sl=:cx=:fn=:ln=:bn=:se=' \
        GREP_COLOR='0' GREP_OPTIONS= &&
        # On Solaris 11.4, /usr/xpg4/bin/sh seems to be less POSIX compliant
        # than /bin/sh (!), as it is the only shell among all tested that:
        # 1. violated the rule "Unsetting a variable or function
        # that was not previously set shall not be considered an error
        # and does not cause the shell to abort."
        # ―https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_29_03
        # 2. failed to parse the rreadlink function.
        \unset -f awk basename cat cd chmod command cp cut \
            date dd diff dirname echo find fuser getopts grep \
            id ls m4 mkdir mv printf pwd read rm sed sort stty \
            tput true umask unalias uname uniq wc &&
        \unalias -a && {
        # The pipefail option was added in POSIX.1-2024 (SUSv5),
        # and has long been supported by most major POSIX-compatible shells,
        # with the notable exceptions of dash and ksh88-based shells.
        # There are some caveats to switching on this option though:
        # https://mywiki.wooledge.org/BashPitfalls#set_-euo_pipefail.
        # Note that we should test in a subshell first so that
        # the non-interactive POSIX sh is never aborted by an error in set,
        # a special built-in utility:
        # https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_08_01.
        # "In POSIX sh, set option pipefail is undefined."
        # shellcheck disable=SC3040
        (set -o pipefail 2>/dev/null) && set -o pipefail
        # Disable the nounset option as yash enables it by default,
        # which is both inconvenient and against the POSIX recommendation.
        # Use ShellCheck or ${parameter?word} to catch unset variables instead.
        set +u
    } && {
        unset -f '[' 2>/dev/null || # [: invalid function name (some ksh).
            command -V '[' | { ! command -p grep -q function; }
    } && {
        IFS=$(command -p printf '%b' ' \n\t') || unset -v IFS
    } && {
        standard_path=$(command -p getconf PATH 2>/dev/null) &&
            export PATH="$standard_path:$PATH" ||
            [ "$?" -eq 127 ] # getconf: command not found (Haiku).
    } &&
        umask 0077 && # cp/mv needs execute access to parent directories.
        # Inspired by https://stackoverflow.com/q/1101957.
        exit_status_definitions() {
            cut -d'#' -f1 <<'EOF'
_EX_OK=0           # Successful exit status.
_EX_FAIL=1         # Failed exit status.
_EX_USAGE=2        # Command line usage error.
_EX__BASE=64       # Base value for error messages.
_EX_DATAERR=65     # Data format error.
_EX_NOINPUT=66     # Cannot open input.
_EX_NOUSER=67      # Addressee unknown.
_EX_NOHOST=68      # Host name unknown.
_EX_UNAVAILABLE=69 # Service unavailable.
_EX_SOFTWARE=70    # Internal software error.
_EX_OSERR=71       # System error (e.g., can't fork).
_EX_OSFILE=72      # Critical OS file missing.
_EX_CANTCREAT=73   # Can't create (user) output file.
_EX_IOERR=74       # Input/output error.
_EX_TEMPFAIL=75    # Temp failure; user is invited to retry.
_EX_PROTOCOL=76    # Remote error in protocol.
_EX_NOPERM=77      # Permission denied.
_EX_CONFIG=78      # Configuration error.
_EX_NOEXEC=126     # A file to be executed was found, but it was not an executable utility.
_EX_CNF=127        # A utility to be executed was not found.
EOF
        } &&
            exit_status_definitions >/dev/null || {
            status=$? || return
            echo 'Failed to initialize the environment.' >&2
            return "$status"
        }
    while IFS='=' read -r name code; do
        code=$(trim "$code") # Needed for zsh and yash.
        # "When reporting the exit status with the special parameter '?',
        # the shell shall report the full eight bits of exit status available."
        # ―https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_08_02
        # "exit [n]: If n is specified, but its value is not between 0 and 255
        # inclusively, the exit status is undefined."
        # ―https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_21
        is_integer "$code" && [ "$code" -ge 0 ] && [ "$code" -le 255 ] || {
            printf '%s %s\n' 'Undefined exit status in the definition:' \
                "$name=$code." >&2
            return 70 # Internal software error.
        }
        (eval readonly "$name=$code" 2>/dev/null) &&
            eval readonly "$name=$code" || {
            eval [ "\"\$$name\"" = "$code" ] &&
                continue # $name is already readonly and set to $code.
            printf '%s %s\n' "Failed to make the exit status $name readonly." \
                'Try again in a new shell environment?' >&2
            return 75 # Temp failure.
        }
    done <<EOF
$(exit_status_definitions)
EOF
}

# Copied from https://unix.stackexchange.com/a/172109.
is_integer() { # arg: [name]
    case $1 in
        "" | - | *[!0123456789-]* | ?*-*) return 1 ;;
        *) return 0 ;;
    esac
}

is_option_set() { # arg: [name]
    [ "${1:-0}" != 0 ] && [ "$1" != false ]
}

missing_utilities() { #args: [name]...
    print_error "Failed to find the following utilities on your system: $*."
    return "${_EX_CNF:?}"
}

print_error() { # args: [ARGUMENT]...
    printf '%s\n' "${_TPUT_AF_RED}ERROR: $*${_TPUT_SGR0}" >&2
}

print_info() { # args: [ARGUMENT]...
    printf '%b' "$*" >&2
}

print_ok() { # args: [ARGUMENT]...
    printf '%s\n' "${_TPUT_AF_GREEN}OK: $*${_TPUT_SGR0}" >&2
}

print_warning() { # args: [ARGUMENT]...
    printf '%s\n' "${_TPUT_AF_YELLOW}WARNING: $*${_TPUT_SGR0}" >&2
}

print_yN() { # args: [ARGUMENT]...
    printf '%s' "${_TPUT_AF_RED}$* [y/N]${_TPUT_SGR0} " >&2
}

probe_fuser_() {
    fuser_() { # arg: FILE
        result=
        case $FUSER__IMPLEMENTATION in
            fuser) result=$(command fuser -- "$1" 2>/dev/null) || return ;;
            lsof)
                # BusyBox lsof ignores all options and arguments.
                result=$(command lsof -lnPt -- "$1") || return
                ;;
            fstat)
                # Begin after the header line.
                # Seems non-functional on DragonFly 6.4
                # if used with an argument.
                result=$(command fstat -- "$1" | tail -n +2) || return
                ;;
            fdinfo) # Haiku
                result=$(command fdinfo -f -- "$1") || return
                ;;
            *)
                missing_utilities "$FUSER__IMPLEMENTATION"
                return
                ;;
        esac
        [ -n "$result" ]
    } || return
    set -- fuser lsof fstat fdinfo
    for util in "$@"; do
        [ "${FUSER__IMPLEMENTATION:-"$util"}" = "$util" ] || continue
        if command -v -- "$util" >/dev/null; then
            FUSER__IMPLEMENTATION=$util
            return
        fi
    done
    FUSER__IMPLEMENTATION= || return
    # "Possible misspelling: PROBE_MISSING may not be assigned. Did you mean probe_missing?"
    # shellcheck disable=SC2153
    ! is_option_set "$PROBE_MISSING" || missing_utilities "$@"
}

probe_mktemp_() {
    mktemp_() {
        case $MKTEMP__IMPLEMENTATION in
            mktemp) command mktemp ;;
            m4)
                # Copied from https://unix.stackexchange.com/a/181996.
                echo 'mkstemp(template)' |
                    m4 -D template="${TMPDIR:-/tmp}/baseXXXXXX"
                ;;
            *) missing_utilities "$MKTEMP__IMPLEMENTATION" ;;
        esac
    } || return
    set -- mktemp m4
    for util in "$@"; do
        [ "${MKTEMP__IMPLEMENTATION:-"$util"}" = "$util" ] || continue
        if command -v -- "$util" >/dev/null; then
            MKTEMP__IMPLEMENTATION=$util
            return
        fi
    done
    MKTEMP__IMPLEMENTATION= || return
    ! is_option_set "$PROBE_MISSING" || missing_utilities "$@"
}

probe_realpath_() {
    # Adjusted from https://stackoverflow.com/a/29835459
    # to match the behavior of the POSIX realpath -E:
    # https://pubs.opengroup.org/onlinepubs/9799919799/utilities/realpath.html.
    # Execute in a subshell to localize variables and the effect of cd.
    rreadlink() ( # arg: FILE
        target=$1 &&
            directory_name= &&
            file_name= &&
            target_directory= &&
            CDPATH= ||
            return
        while :; do
            directory_name=$(dirname -- "$target") || return
            [ -L "$target" ] || [ -e "$target" ] || [ -e "$directory_name" ] || {
                print_error "'$target' does not exist."
                return "${_EX_FAIL:?}"
            }
            cd -- "$directory_name" || return
            file_name=$(basename -- "$target") || return
            [ "$file_name" = '/' ] && file_name='' # `basename /` returns '/'.
            if [ -L "$file_name" ]; then
                target=$(ls -l -- "$file_name") || return
                target=${target#* -> }
                continue
            fi
            break
        done
        target_directory=$(pwd -P) || return
        if [ "$file_name" = '.' ]; then
            printf '%s\n' "${target_directory%/}"
        elif [ "$file_name" = '..' ]; then
            printf '%s\n' "$(dirname -- "${target_directory}")"
        else
            printf '%s\n' "${target_directory%/}/$file_name"
        fi
    ) || return
    realpath_() { # args: FILE...
        if [ "$#" -le 0 ]; then
            echo 'realpath_: missing operand' >&2
            return "${_EX_USAGE:?}"
        else
            return_status=${_EX_OK:?} || return
            while [ "$#" -gt 0 ]; do
                case $REALPATH__IMPLEMENTATION in
                    realpath) command realpath -- "$1" ;;
                    readlink) command readlink -f -- "$1" ;;
                    greadlink) command greadlink -f -- "$1" ;;
                    *) rreadlink "$1" ;;
                esac
                status=$? || return
                [ "$status" -eq "${_EX_OK:?}" ] || return_status=$status
                shift
            done
            return "$return_status"
        fi
    } || return
    # Both realpath and readlink -f as found on the BSDs are quite different
    # from their Linux counterparts and even among themselves,
    # instead behaving similarly to the POSIX realpath -e for the most part.
    # The table below details the varying behaviors where the non-header cells
    # note the exit status followed by any output in parentheses:
    # |               | realpath nosuchfile | realpath nosuchtarget | readlink -f nosuchfile | readlink -f nosuchtarget |
    # |---------------|---------------------|-----------------------|------------------------|--------------------------|
    # | FreeBSD 14.2  | 1 (error message)   | 1 (error message)     | 1                      | 1 (fully resolved path)  |
    # | OpenBSD 7.6   | 1 (error message)   | 1 (error message)     | 1 (error message)      | 1 (error message)        |
    # | NetBSD 10.0   | 0                   | 0                     | 1                      | 1 (fully resolved path)  |
    # | DragonFly 6.4 | 1 (error message)   | 1 (error message)     | 1                      | 1 (input path argument)  |
    # It is also worth pointing out that the BusyBox (v1.37.0)
    # realpath and readlink -f exit with status 1 without outputting
    # the fully resolved path if the argument contains no slash characters
    # and does not name a file in the current directory.
    case $(uname) in
        NetBSD) : ;;      # NetBSD realpath works as intended.
        *BSD | DragonFly) # Other BSDs need to switch to rreadlink.
            REALPATH__IMPLEMENTATION=${REALPATH__IMPLEMENTATION:-rreadlink} ||
                return
            ;;
    esac
    for util in realpath readlink greadlink; do
        [ "${REALPATH__IMPLEMENTATION:-"$util"}" = "$util" ] || continue
        if case $util in
            readlink | greadlink) command "$util" -f -- . >/dev/null 2>&1 ;;
            *) command "$util" -- . >/dev/null 2>&1 ;;
        esac then
            REALPATH__IMPLEMENTATION=$util
            return
        fi
    done
    REALPATH__IMPLEMENTATION=rreadlink
}

# https://mywiki.wooledge.org/BashFAQ/037
probe_terminal() {
    # Testing for multiple terminal capabilities at once is unreliable,
    # and the non-POSIX option -S is not recognized by NetBSD's tput,
    # which also requires a numerical argument after setaf/AF,
    # so we test thus, trying both terminfo and termcap names just in case
    # (see https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=214709):
    if [ -t 2 ]; then
        tput setaf 0 >/dev/null 2>&1 &&
            tput bold >/dev/null 2>&1 &&
            tput sgr0 >/dev/null 2>&1 &&
            _TPUT_AF_RED=$(tput setaf 1) &&
            _TPUT_AF_GREEN=$(tput setaf 2) &&
            _TPUT_AF_YELLOW=$(tput setaf 3) &&
            _TPUT_AF_BLUE=$(tput setaf 4) &&
            _TPUT_AF_CYAN=$(tput setaf 6) &&
            _TPUT_BOLD_AF_BLUE=$(tput bold)$(tput setaf 4) &&
            _TPUT_SGR0=$(tput sgr0) &&
            return
        tput AF 0 >/dev/null 2>&1 &&
            tput md >/dev/null 2>&1 &&
            tput me >/dev/null 2>&1 &&
            _TPUT_AF_RED=$(tput AF 1) &&
            _TPUT_AF_GREEN=$(tput AF 2) &&
            _TPUT_AF_YELLOW=$(tput AF 3) &&
            _TPUT_AF_BLUE=$(tput AF 4) &&
            _TPUT_AF_CYAN=$(tput AF 6) &&
            _TPUT_BOLD_AF_BLUE=$(tput md)$(tput AF 4) &&
            _TPUT_SGR0=$(tput me) &&
            return
    fi
    : &&
        _TPUT_AF_RED= &&
        _TPUT_AF_GREEN= &&
        _TPUT_AF_YELLOW= &&
        _TPUT_AF_BLUE= &&
        _TPUT_AF_CYAN= &&
        _TPUT_BOLD_AF_BLUE= &&
        _TPUT_SGR0=
}

probe_wget_() {
    wget_() { # args: FILE URL
        case $WGET__IMPLEMENTATION in
            curl)
                http_code=$(
                    command curl -sSfw '%{http_code}' -o "$1" -- "$2"
                ) &&
                    is_integer "$http_code" &&
                    [ "$http_code" -ge 200 ] &&
                    [ "$http_code" -lt 300 ]
                ;;
            wget) command wget -O "$1" -- "$2" ;;
            fetch) command fetch -o "$1" -- "$2" ;;
            ftp) command ftp -o "$1" -- "$2" ;; # Progress meter to stdout.
            *) missing_utilities "$WGET__IMPLEMENTATION" ;;
        esac
    } || return
    set -- curl wget fetch ftp
    for util in "$@"; do
        [ "${WGET__IMPLEMENTATION:-"$util"}" = "$util" ] || continue
        if command -v -- "$util" >/dev/null 2>&1; then
            WGET__IMPLEMENTATION=$util
            return
        fi
    done
    WGET__IMPLEMENTATION= || return
    ! is_option_set "$PROBE_MISSING" || missing_utilities "$@"
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

# Copied from https://stackoverflow.com/a/3352015.
trim() { # arg: [name]
    var=$1 || return
    # Remove leading whitespace characters.
    var=${var#"${var%%[![:space:]]*}"}
    # Remove trailing whitespace characters.
    var=${var%"${var##*[![:space:]]}"}
    printf '%s' "$var"
}

# https://kb.mozillazine.org/Profile_folder_-_Firefox#Files
# https://searchfox.org/mozilla-central/source/toolkit/profile/nsProfileLock.cpp
arkenfox_check_firefox_profile_lock() { # arg: DIRECTORY
    lock_file=${1%/}/.parentlock || return
    while [ -f "$lock_file" ] && fuser_ "$lock_file" ||
        arkenfox_is_firefox_profile_symlink_locked "$1"; do
        print_warning 'This Firefox profile seems to be in use.' \
            'Close Firefox and try again.'
        print_info '\nPress any key to continue. '
        read1 REPLY
        print_info '\n\n'
    done
}

arkenfox_is_firefox_profile_symlink_locked() { # arg: DIRECTORY
    if [ "$(uname)" = 'Darwin' ]; then         # macOS
        symlink_lock=${1%/}/.parentlock
    else
        symlink_lock=${1%/}/lock
    fi &&
        [ -L "$symlink_lock" ] &&
        symlink_lock_target=$(realpath_ "$symlink_lock") ||
        return
    lock_signature=$(
        basename -- "$symlink_lock_target" |
            sed -n 's/^\(.*\):+\{0,1\}\([0123456789]\{1,\}\)$/\1:\2/p'
    ) &&
        [ -n "$lock_signature" ] &&
        lock_acquired_ip=${lock_signature%:*} &&
        lock_acquired_pid=${lock_signature##*:} || {
        print_error 'Failed to resolve the symlink target signature' \
            "of the lock file: $symlink_lock."
        return "${_EX_DATAERR:?}"
    }
    if [ "$lock_acquired_ip" = '127.0.0.1' ]; then
        kill -s 0 "$lock_acquired_pid" 2>/dev/null
    else
        print_warning 'Unable to determine if the Firefox profile is being used.'
        print_yN 'Proceed anyway?'
        read1 REPLY
        print_info '\n\n'
        [ "$REPLY" = 'Y' ] || [ "$REPLY" = 'y' ] || return "${_EX_OK:?}"
        return "${_EX__BASE:?}"
    fi
}

arkenfox_script_version() { # arg: {updater.sh|prefsCleaner.sh}
    version_format='[0123456789]\{1,\}\.[0123456789]\{1,\}' &&
        version=$(
            sed -n -- "5s/.*version:[[:blank:]]*\($version_format\).*/\1/p" \
                "$1"
        ) &&
        [ -n "$version" ] &&
        printf '%s\n' "$version" || {
        print_error "Failed to determine the version of the script file: $1."
        return "${_EX_DATAERR:?}"
    }
}

# Restore the starting sh options.
eval "$_ARKENFOX_STARTING_SHOPTS" || return 2>/dev/null || exit

###############################################################################
####              === prefsCleaner.sh specific functions ===               ####
###############################################################################

# Detect spoofing by external, readonly functions.
set -e || return 2>/dev/null || exit

arkenfox_prefs_cleaner_init() {
    # Variable assignments before a function might actually persist
    # after the completion of the function, which they do in both ksh and zsh:
    # https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_09_01.
    probe_missing=$PROBE_MISSING &&
        probe_terminal &&
        PROBE_MISSING=0 probe_wget_ &&
        PROBE_MISSING=0 probe_mktemp_ &&
        PROBE_MISSING=$probe_missing probe_fuser_ &&
        probe_realpath_ ||
        return
    # IMPORTANT! ARKENFOX_PREFS_CLEANER_NAME must be synced to the name of this file!
    # This is so that we may somewhat determine if the script is sourced or not
    # by comparing it to the basename of the canonical path of $0,
    # which should be better than hard coding all the names of the
    # interactive and non-interactive POSIX shells in existence.
    # Cf. https://stackoverflow.com/a/28776166.
    ARKENFOX_PREFS_CLEANER_NAME=${ARKENFOX_PREFS_CLEANER_NAME:-prefsCleaner.sh}
    run_path=$(realpath_ "$0") &&
        run_dir=$(dirname -- "$run_path") &&
        run_name=$(basename -- "$run_path") || {
        print_error 'Failed to resolve the run file path.'
        return "${_EX_UNAVAILABLE:?}"
    }
    (
        _ARKENFOX_PREFS_CLEANER_RUN_PATH=$run_path &&
            _ARKENFOX_PREFS_CLEANER_RUN_DIR=$run_dir &&
            _ARKENFOX_PREFS_CLEANER_RUN_NAME=$run_name
    ) 2>/dev/null &&
        _ARKENFOX_PREFS_CLEANER_RUN_PATH=$run_path &&
        _ARKENFOX_PREFS_CLEANER_RUN_DIR=$run_dir &&
        _ARKENFOX_PREFS_CLEANER_RUN_NAME=$run_name &&
        readonly _ARKENFOX_PREFS_CLEANER_RUN_PATH \
            _ARKENFOX_PREFS_CLEANER_RUN_DIR \
            _ARKENFOX_PREFS_CLEANER_RUN_NAME || {
        [ "$_ARKENFOX_PREFS_CLEANER_RUN_PATH" = "$run_path" ] &&
            [ "$_ARKENFOX_PREFS_CLEANER_RUN_DIR" = "$run_dir" ] &&
            [ "$_ARKENFOX_PREFS_CLEANER_RUN_NAME" = "$run_name" ] || {
            print_error 'Failed to make the resolved run file path readonly.' \
                'Try again in a new shell environment?'
            return "${_EX_TEMPFAIL:?}"
        }
    }
}

arkenfox_prefs_cleaner() { # args: [options]
    arkenfox_prefs_cleaner_parse_options "$@" &&
        arkenfox_prefs_cleaner_set_profile_path &&
        arkenfox_prefs_cleaner_check_nonroot || return
    is_option_set "$_ARKENFOX_PREFS_CLEANER_OPTION_D_DONT_UPDATE" ||
        arkenfox_prefs_cleaner_update_self "$@" || return
    arkenfox_prefs_cleaner_banner
    if is_option_set "$_ARKENFOX_PREFS_CLEANER_OPTION_S_START"; then
        arkenfox_prefs_cleaner_start || return
    else
        print_info 'In order to proceed, select a command below' \
            'by entering its corresponding number.\n\n'
        while print_info '1) Start\n2) Help\n3) Exit\n'; do
            while print_info '#? ' && read -r REPLY; do
                case $REPLY in
                    1)
                        arkenfox_prefs_cleaner_start
                        return
                        ;;
                    2)
                        arkenfox_prefs_cleaner_usage
                        arkenfox_prefs_cleaner_help
                        return
                        ;;
                    3) return ;;
                    '') break ;;
                    *) : ;;
                esac
            done
        done
    fi
}

arkenfox_prefs_cleaner_usage() {
    cat >&2 <<EOF

Usage: $ARKENFOX_PREFS_CLEANER_NAME [-ds]

Options:
    -s           Start immediately.
    -d           Don't auto-update prefsCleaner.sh.

EOF
}

arkenfox_prefs_cleaner_parse_options() { # args: [options]
    # OPTIND must be manually reset between multiple calls to getopts.
    OPTIND=1 &&
        # IMPORTANT! Make sure to initialize all options!
        _ARKENFOX_PREFS_CLEANER_OPTION_D_DONT_UPDATE= &&
        _ARKENFOX_PREFS_CLEANER_OPTION_S_START= ||
        return
    while getopts 'sd' opt; do
        case $opt in
            s) _ARKENFOX_PREFS_CLEANER_OPTION_S_START=1 ;;
            d) _ARKENFOX_PREFS_CLEANER_OPTION_D_DONT_UPDATE=1 ;;
            \?)
                arkenfox_prefs_cleaner_usage
                return "${_EX_USAGE:?}"
                ;;
        esac
    done
    if [ -z "$MKTEMP__IMPLEMENTATION" ] || [ -z "$WGET__IMPLEMENTATION" ]; then
        is_option_set "$_ARKENFOX_PREFS_CLEANER_OPTION_D_DONT_UPDATE" ||
            print_warning 'Unable to find curl or wget on your system.' \
                'Automatic self-update disabled!'
        _ARKENFOX_PREFS_CLEANER_OPTION_D_DONT_UPDATE=1
    fi
}

arkenfox_prefs_cleaner_set_profile_path() {
    _ARKENFOX_PROFILE_PATH=$(realpath_ "$_ARKENFOX_PREFS_CLEANER_RUN_DIR") &&
        [ -w "$_ARKENFOX_PROFILE_PATH" ] &&
        cd -- "$_ARKENFOX_PROFILE_PATH" || {
        print_error 'The path to your Firefox profile' \
            "('$_ARKENFOX_PROFILE_PATH') failed to be a directory to which" \
            'the user has both write and execute access.'
        return "${_EX_UNAVAILABLE:?}"
    }
    _ARKENFOX_PROFILE_USERJS=${_ARKENFOX_PROFILE_PATH%/}/user.js &&
        _ARKENFOX_PROFILE_PREFSJS=${_ARKENFOX_PROFILE_PATH%/}/prefs.js &&
        _ARKENFOX_PROFILE_PREFSJS_BACKUP_DIR=${_ARKENFOX_PROFILE_PATH%/}/prefsjs_backups
}

arkenfox_prefs_cleaner_check_nonroot() {
    uid=$(id -u) || return
    if is_integer "$uid" && [ "$uid" -eq 0 ]; then
        print_error "You shouldn't run this with elevated privileges" \
            '(such as with doas/sudo).'
        return "${_EX_USAGE:?}"
    fi
}

arkenfox_prefs_cleaner_update_self() { # args: [options]
    # Here, we use _ARKENFOX_PROFILE_PATH/ARKENFOX_PREFS_CLEANER_NAME
    # instead of _ARKENFOX_PREFS_CLEANER_RUN_PATH as the latter would be
    # incorrect if the script is sourced.
    [ -e "${_ARKENFOX_PREFS_CLEANER_RUN_PATH:?}" ] &&
        arkenfox_prefs_cleaner=$_ARKENFOX_PREFS_CLEANER_RUN_PATH &&
        master_prefs_cleaner=$(
            download_file \
                'https://raw.githubusercontent.com/arkenfox/user.js/master/prefsCleaner.sh'
        ) &&
        local_version=$(arkenfox_script_version "$arkenfox_prefs_cleaner") &&
        master_version=$(arkenfox_script_version "$master_prefs_cleaner") ||
        return
    local_major_version=${local_version%%.*} &&
        local_minor_version=${local_version#*.} &&
        master_major_version=${master_version%%.*} &&
        master_minor_version=${master_version#*.} &&
        is_integer "$local_major_version" &&
        is_integer "$local_minor_version" &&
        is_integer "$master_major_version" &&
        is_integer "$master_minor_version" || {
        print_error 'Failed to parse the major and minor parts' \
            'of the version strings.'
        return "${_EX_DATAERR:?}"
    }
    if [ "$local_major_version" -eq "$master_major_version" ] &&
        [ "$local_minor_version" -lt "$master_minor_version" ] ||
        [ "$local_major_version" -lt "$master_major_version" ]; then
        mv -f -- "$master_prefs_cleaner" "$arkenfox_prefs_cleaner" &&
            chmod -- u+rx "$arkenfox_prefs_cleaner" || {
            print_error 'Failed to update the arkenfox prefs.js cleaner' \
                'and make it executable.'
            return "${_EX_CANTCREAT:?}"
        }
        "$arkenfox_prefs_cleaner" -d "$@"
    fi
}

arkenfox_prefs_cleaner_banner() {
    cat >&2 <<'EOF'



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

arkenfox_prefs_cleaner_help() {
    cat >&2 <<'EOF'

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

arkenfox_prefs_cleaner_start() {
    [ -f "${_ARKENFOX_PROFILE_USERJS:?}" ] &&
        [ -f "${_ARKENFOX_PROFILE_PREFSJS:?}" ] || {
        print_error 'Failed to find both user.js and prefs.js' \
            "in the profile path: ${_ARKENFOX_PROFILE_PATH:?}."
        return "${_EX_NOINPUT:?}"
    }
    arkenfox_check_firefox_profile_lock "${_ARKENFOX_PROFILE_PATH:?}" &&
        backup_dir=${_ARKENFOX_PROFILE_PREFSJS_BACKUP_DIR:?} &&
        prefsjs_backup=$backup_dir/prefs.js.backup.$(date +"%Y-%m-%d_%H%M") ||
        return
    mkdir -p -- "$backup_dir" &&
        cp -- "${_ARKENFOX_PROFILE_PREFSJS:?}" "$prefsjs_backup" || {
        print_error "Failed to backup prefs.js: $prefsjs_backup."
        return "${_EX_CANTCREAT:?}"
    }
    print_ok "Your prefs.js has been backed up: $prefsjs_backup."
    print_info 'Cleaning prefs.js...\n\n'
    arkenfox_prefs_cleaner_clean "$prefsjs_backup" || {
        status=$?
        return
    }
    print_ok 'All done!'
}

# TODO: Check logic and do more testing.
arkenfox_prefs_cleaner_clean() { # arg: prefs.js
    prefs_regex="user_pref[[:blank:]]*\([[:blank:]]*[\"']([^\"']+)[\"'][[:blank:]]*," &&
        all_userjs_prefs=$(
            grep -E -- "$prefs_regex" "${_ARKENFOX_PROFILE_USERJS:?}" |
                awk -F"[\"']" '{ print "\"" $2 "\"" }' |
                sort |
                uniq
        ) || return
    # Will underclean if prefs in "$1" use single quotation marks.
    unneeded_prefs=$(
        printf '%s\n' "$all_userjs_prefs" |
            grep -E -f - -- "$1" |
            grep -E -e "^[[:blank:]]*$prefs_regex"
    ) ||
        # It is not an error if there are no unneeded prefs to clean.
        [ "$?" -eq "${_EX_FAIL:?}" ] || return
    if [ -n "$unneeded_prefs" ]; then
        prefsjs_temp=$(mktemp_) &&
            printf '%s\n' "$unneeded_prefs" |
            grep -v -f - -- "$1" >|"$prefsjs_temp" &&
            mv -f -- "$prefsjs_temp" "${_ARKENFOX_PROFILE_PREFSJS:?}"
    fi
}

# Restore the starting sh options.
eval "$_ARKENFOX_STARTING_SHOPTS" || return 2>/dev/null || exit

# "Command appears to be unreachable. Check usage (or ignore if invoked indirectly)."
# shellcheck disable=SC2317
(main() { :; }) && true # For quick navigation in IDEs only.
init && arkenfox_prefs_cleaner_init
init_status=$? &&
    if [ "$init_status" -eq 0 ]; then
        if [ "$_ARKENFOX_PREFS_CLEANER_RUN_NAME" = "$ARKENFOX_PREFS_CLEANER_NAME" ]; then
            arkenfox_prefs_cleaner "$@"
        else
            print_ok 'The prefs.js cleaner script has been successfully sourced.'
            print_warning 'If this is not intentional,' \
                'you may have either made a typo in the shell commands,' \
                'or renamed this file without defining the environment variable' \
                'ARKENFOX_PREFS_CLEANER_NAME to match the new name.' \
                "

         Detected name of the run file: $_ARKENFOX_PREFS_CLEANER_RUN_NAME
         ARKENFOX_PREFS_CLEANER_NAME  : $ARKENFOX_PREFS_CLEANER_NAME
" \
                "$(printf '%s\n\b' '')Please note that this is not" \
                'the expected way to run the prefs.js cleaner script.' \
                'Dot sourcing support is experimental' \
                'and all function and variable names are still subject to change.'
            # Make arkenfox_prefs_cleaner_update_self a no-op as this function
            # can not be run reliably when dot-sourced.
            eval 'arkenfox_prefs_cleaner_update_self() { :; }'
        fi
    else
        # '&& true' to avoid exiting the shell if the shell option errexit is set.
        (exit "$init_status") && true
    fi
