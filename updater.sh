#!/bin/sh

# arkenfox user.js updater for macOS, Linux and Unix-like operating systems
# authors: @overdodactyl, @earthlng, @9ao9ai9ar
# version: 5.0

# IMPORTANT! The version string must be on the 5th line of this file
# and must be of the format "version: MAJOR.MINOR" (spaces are optional).
# This restriction is set by the function arkenfox_script_version.

# Example advanced script usage:
# $ yes | env WGET__IMPLEMENTATION=wget ./updater.sh >/dev/null 2>&1
# $ TERM=dumb . ./updater.sh && arkenfox_updater

# This ShellCheck warning is just noise for those who know what they are doing:
# "Note that A && B || C is not if-then-else. C may run when A is true."
# shellcheck disable=SC2015

###############################################################################
####                   === Common utility functions ===                    ####
#### Code that is shared between updater.sh and prefsCleaner.sh, inlined   ####
#### and duplicated only to maintain the same file count as before.        ####
###############################################################################

# Save the starting sh options for later restoration.
_ARKENFOX_STARTING_SHOPTS=$(\set +o) &&
    # Workaround for bash (see https://unix.stackexchange.com/a/383581):
    case $- in
        *e*)
            _ARKENFOX_STARTING_SHOPTS="$_ARKENFOX_STARTING_SHOPTS; set -o errexit"
            ;;
        *)
            _ARKENFOX_STARTING_SHOPTS="$_ARKENFOX_STARTING_SHOPTS; set +o errexit"
            ;;
    esac &&
    # Ensure no function of the same name is invoked before unalias the utility
    # (see https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_09_01_01),
    \unset -f unalias &&
    # which must be run asap as alias substitution occurs right before parsing:
    # https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_03_01.
    \unalias -a &&
    # Detect spoofing by external, readonly functions.
    set -o errexit ||
    \return 2>/dev/null || \exit

download_file() { # arg: URL
    # The try-finally construct can be implemented as a set of trap commands.
    # However, it is notoriously difficult to write them portably and reliably.
    # Since mktemp_ creates temporary files that are periodically cleared
    # on any sane system, we leave it to the OS or the user
    # to do the cleaning themselves for simplicity's sake.
    temp=$(mktemp_) &&
        wget_ "$temp" "$1" >/dev/null 2>&1 &&
        printf '%s\n' "$temp" || {
        print_error "Failed to download file from the URL: $1."
        return "${_EX_UNAVAILABLE:?}"
    }
}

# An improvement on the "secure shell script" example demonstrated in
# https://pubs.opengroup.org/onlinepubs/9699919799/utilities/command.html#tag_20_22_17.
init() {
    LC_ALL=C &&
        # To prevent the accidental insertion of SGR commands in grep's output,
        # even when not directed at a terminal, we explicitly set
        # the following three environment variables:
        GREP_COLORS='mt=:ms=:mc=:sl=:cx=:fn=:ln=:bn=:se=' &&
        GREP_COLOR='0' &&
        GREP_OPTIONS= &&
        \export LC_ALL GREP_COLORS GREP_COLOR GREP_OPTIONS &&
        # Unset all functions whose name is the same as any of
        # the standard utilities used in the arkenfox scripts.
        # If a function by that name is not already defined, a >0 exit status
        # may be returned in some ksh88 derivatives like the pdksh and XPG4 sh.
        # While this is technically not against the requirement
        # "Unsetting a variable or function that was not previously set shall
        # not be considered an error and does not cause the shell to abort."
        # ―https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_29_03
        # it runs counter to what most people perceive to be
        # the correct behavior and what most shells actually do in such case.
        \unset -f awk basename cat cd chmod command cp cut \
            date dd diff dirname echo find fuser getopts grep \
            id ls m4 mkdir mv printf pwd read rm sed sort stty \
            tput umask unalias uname uniq wc &&
        # It is already too late for running the unalias command,
        # but might still be useful in the case the script is dot sourced,
        # acting as a reset mechanism.
        \unalias -a && {
        # The pipefail option was added in POSIX.1-2024 (SUSv5),
        # and has long been supported by most major POSIX-compatible shells,
        # with the notable exceptions of dash and ksh88-based shells.
        # There are some caveats to switching on this option though:
        # https://mywiki.wooledge.org/BashPitfalls#set_-euo_pipefail.
        # Note that we should test in a subshell first so that
        # the non-interactive shell is not aborted by an error in set,
        # a special built-in utility:
        # https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_08_01.
        # "In POSIX sh, set option pipefail is undefined."
        # shellcheck disable=SC3040
        (set -o pipefail 2>/dev/null) && set -o pipefail
        # Disable the nounset option as yash enables it by default,
        # which is both inconvenient and against the POSIX recommendation.
        # Use ShellCheck or ${parameter?word} to catch unset variables instead.
        set +o nounset
    } && {
        unset -f '[' 2>/dev/null || # This triggers an error in some ksh88.
            command -V '[' | { ! command -p grep -q function; }
    } && {
        IFS=$(command -p printf '%b' ' \n\t') || unset -v IFS
    } && {
        path=$(command -p getconf PATH 2>/dev/null) &&
            PATH="$path:$PATH" &&
            export PATH ||
            [ "$?" -eq 127 ] # getconf: command not found (Haiku).
    } &&
        umask 0077 && # cp/mv need execute access to parent directories.
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
        code=$(trim "$code") || return
        # "When reporting the exit status with the special parameter '?',
        # the shell shall report the full eight bits of exit status available."
        # ―https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_08_02
        # "exit [n]: If n is specified, but its value is not between
        # 0 and 255 inclusively, the exit status is undefined."
        # ―https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_21
        is_integer "$code" && [ "$code" -ge 0 ] && [ "$code" -le 255 ] || {
            printf '%s %s\n' 'Undefined exit status in the definition:' \
                "$name=$code." >&2
            return 70 # Internal software error.
        }
        (
            eval "$name=$code" 2>/dev/null &&
                eval readonly "$name" 2>/dev/null
        ) &&
            eval "$name=$code" &&
            eval readonly "$name" || {
            eval [ "\"\$$name\"" = "$code" ] &&
                continue # $name is already readonly and set to $code.
            printf '%s %s\n' \
                "Failed to assign $code to $name and make $name readonly." \
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

print_error() { # args: [ARGUMENT]...
    printf '%s\n' "${_TPUT_AF_RED}ERROR: $*${_TPUT_SGR0}" >&2
}

print_info() { # args: [ARGUMENT]...
    printf '%b' "$*" >&2
}

print_missing() { #args: [ARGUMENT]...
    print_error "Failed to find the following utilities on your system: $*."
    return "${_EX_CNF:?}"
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

probe_mktemp_() { # arg: [IMPLEMENTATION]
    mktemp_() {
        case $MKTEMP__IMPLEMENTATION in
            mktemp) command mktemp ;;
            m4)
                # Copied from https://unix.stackexchange.com/a/181996.
                echo 'mkstemp(template)' |
                    m4 -D template="${TMPDIR:-/tmp}/baseXXXXXX"
                ;;
            *) print_missing mktemp m4 ;;
        esac
    } || return
    MKTEMP__IMPLEMENTATION=$1 && util= && set -- mktemp m4 || return
    for util in "$@"; do
        [ "${MKTEMP__IMPLEMENTATION:-"$util"}" = "$util" ] || continue
        if command -v -- "$util" >/dev/null; then
            MKTEMP__IMPLEMENTATION=$util
            return
        else
            [ "$MKTEMP__IMPLEMENTATION" = "$util" ] || continue
            print_missing "$util"
            return
        fi
    done
    print_missing "$@"
}

probe_open_() { # arg: [IMPLEMENTATION]
    open_() {   # args: FILE...
        if [ "$#" -eq 0 ]; then
            echo 'open_: missing operand' >&2
            return "${_EX_USAGE:?}"
        else
            return_status=${_EX_OK:?} || return
            while [ "$#" -gt 0 ]; do
                case $OPEN__IMPLEMENTATION in
                    xdg-open | open)
                        # Do not add --, as xdg-open does not conform to the
                        # XBD Utility Syntax Guidelines.
                        command "$OPEN__IMPLEMENTATION" "$1"
                        ;;
                    firefox)
                        # Do not add --, as firefox does not conform to the
                        # XBD Utility Syntax Guidelines.
                        command firefox "$@"
                        return
                        ;;
                    *)
                        print_missing xdg-open open firefox
                        return
                        ;;
                esac
                status=$? || return
                [ "$status" -eq "${_EX_OK:?}" ] || return_status=$status
                shift
            done
            return "$return_status"
        fi
    } || return
    OPEN__IMPLEMENTATION=$1 && util= && set -- xdg-open open firefox || return
    for util in "$@"; do
        [ "${OPEN__IMPLEMENTATION:-"$util"}" = "$util" ] || continue
        if command -v -- "$util" >/dev/null; then
            OPEN__IMPLEMENTATION=$util
            return
        else
            [ "$OPEN__IMPLEMENTATION" = "$util" ] || continue
            print_missing "$util"
            return
        fi
    done
    print_missing "$@"
}

probe_realpath_() { # arg: [IMPLEMENTATION]
    # Adjusted from https://stackoverflow.com/a/29835459
    # to match the behavior of the POSIX realpath -E:
    # https://pubs.opengroup.org/onlinepubs/9799919799/utilities/realpath.html.
    # Execute in a subshell to localize variables and the effect of cd.
    rreadlink() ( # arg: FILE
        target=$1 && dir_name= && base_name= && target_dir= && CDPATH= || return
        while :; do
            dir_name=$(dirname -- "$target") || return
            [ -L "$target" ] || [ -e "$target" ] || [ -e "$dir_name" ] || {
                print_error "rreadlink: $target: No such file or directory"
                return "${_EX_FAIL:?}"
            }
            cd -- "$dir_name" &&
                base_name=$(basename -- "$target") || return
            [ "$base_name" = '/' ] && base_name= # `basename /` returns '/'.
            if [ -L "$base_name" ]; then
                target=$(ls -l -- "$base_name") &&
                    target=${target#*' -> '} ||
                    return
                continue
            fi
            break
        done
        target_dir=$(pwd -P) || return
        if [ "$base_name" = '.' ]; then
            printf '%s\n' "${target_dir%/}"
        elif [ "$base_name" = '..' ]; then
            printf '%s\n' "$(dirname -- "${target_dir}")"
        else
            printf '%s\n' "${target_dir%/}/$base_name"
        fi
    ) || return
    realpath_() { # args: FILE...
        if [ "$#" -eq 0 ]; then
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
    REALPATH__IMPLEMENTATION=$1 && util= || return
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
    kernel=$(uname) &&
        case $kernel in
            NetBSD) : ;;      # NetBSD realpath works as intended.
            *BSD | DragonFly) # Other BSDs need to switch to rreadlink.
                REALPATH__IMPLEMENTATION=${REALPATH__IMPLEMENTATION:-rreadlink}
                ;;
        esac ||
        return
    set -- realpath readlink greadlink || return
    for util in "$@"; do
        [ "${REALPATH__IMPLEMENTATION:-"$util"}" = "$util" ] || continue
        if case $util in
            readlink | greadlink) command "$util" -f -- . >/dev/null 2>&1 ;;
            *) command "$util" -- . >/dev/null 2>&1 ;;
        esac then
            REALPATH__IMPLEMENTATION=$util
            return
        else
            [ "$REALPATH__IMPLEMENTATION" = "$util" ] || continue
            print_missing "$util"
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
    _TPUT_AF_RED= &&
        _TPUT_AF_GREEN= &&
        _TPUT_AF_YELLOW= &&
        _TPUT_AF_BLUE= &&
        _TPUT_AF_CYAN= &&
        _TPUT_BOLD_AF_BLUE= &&
        _TPUT_SGR0=
}

probe_wget_() { # arg: [IMPLEMENTATION]
    wget_() {   # args: FILE URL
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
            *) print_missing curl wget fetch ftp ;;
        esac
    } || return
    WGET__IMPLEMENTATION=$1 && util= && set -- curl wget fetch ftp || return
    for util in "$@"; do
        [ "${WGET__IMPLEMENTATION:-"$util"}" = "$util" ] || continue
        if command -v -- "$util" >/dev/null 2>&1; then
            WGET__IMPLEMENTATION=$util
            return
        else
            [ "$WGET__IMPLEMENTATION" = "$util" ] || continue
            print_missing "$util"
            return
        fi
    done
    print_missing "$@"
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
# The POSIX character classes are not supported in posh and pdksh:
# https://manpages.debian.org/testing/posh/posh.1.en.html#File_Name_Patterns
# https://linux.die.net/man/1/pdksh
trim() { # arg: [name]
    var=$1 &&
        # Remove leading whitespace characters.
        var=${var#"${var%%[![:space:]]*}"} &&
        # Remove trailing whitespace characters.
        var=${var%"${var##*[![:space:]]}"} &&
        printf '%s' "$var"
}

# https://searchfox.org/mozilla-central/source/modules/libpref/parser/src/lib.rs
# TODO: Handle Python style comments, the third form of comments allowed in user.js.
arkenfox_remove_userjs_comments() { # arg: FILE
    # Copied in full from the public domain sed script at
    # https://sed.sourceforge.io/grabbag/scripts/remccoms3.sed,
    # patched to eliminate any unbalanced parenthesis or quotation mark in
    # here-documents, comments, or case statement patterns,
    # as oksh mishandles them inside the $() form of command substitution
    # (using the `` form is not an option as that introduces other errors):
    # https://www.gnu.org/savannah-checkouts/gnu/autoconf/manual/html_node/Shell-Substitutions.html#index-_0024_0028commands_0029
    # (see also https://unix.stackexchange.com/q/340923).
    # The best POSIX solution on the internet, though it does not handle some
    # edge cases as well as Emacs and cpp do; e.g. compare the output of
    # `cpp -P -std=c99 -fpreprocessed -undef -dD "$1"`
    # (the options "-Werror -Wfatal-errors" could also be added,
    # which may mimic Firefox's parsing of user.js better)
    # with that of `arkenfox_remove_userjs_comments "$1"`, where the content of
    # the input file $1 is the text in the here-document below:
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
    remccoms3=$(
        # Apparently, the redirection operator "<<", but not "<<-", here
        # inside a command substitution breaks the syntax highlighting and the
        # functions outline in the structure tool window of JetBrains IDEs.
        cat <<-'EOF'
#! /bin/sed -nf

# Remove C and C++ comments, by Brian Hiles (brian_hiles@rocketmail.com)

# Sped up (and bugfixed to some extent) by Paolo Bonzini (bonzini@gnu.org)
# Works its way through the line, copying to hold space the text up to the
# first special character (/, '"', "'").  The original version went exactly a
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
    ) &&
        # Setting LC_ALL=C in init helps prevent an indefinite loop:
        # https://stackoverflow.com/q/13061785/#comment93013794_13062074.
        sed -n -- "$remccoms3" "$1" |
        sed '/^[[:space:]]*$/d' # Remove blank lines.
}

# https://kb.mozillazine.org/Profiles.ini_file
arkenfox_select_firefox_profile_path() {
    kernel=$(uname) || return
    if [ "$kernel" = 'Darwin' ]; then # macOS
        profiles_ini=$HOME/Library/Application\ Support/Firefox/profiles.ini
    else
        profiles_ini=$HOME/.mozilla/firefox/profiles.ini
    fi &&
        [ -f "$profiles_ini" ] || {
        print_error 'Failed to find the Firefox profiles.ini file' \
            'at the standard location.'
        return "${_EX_NOINPUT:?}"
    }
    selected_profile=$(arkenfox_select_firefox_profile "$profiles_ini") &&
        path=$(
            printf '%s\n' "$selected_profile" | sed -n 's/^Path=\(.*\)$/\1/p'
        ) &&
        is_relative=$(
            printf '%s\n' "$selected_profile" |
                sed -n 's/^IsRelative=\([01]\)$/\1/p'
        ) ||
        return
    [ -n "$path" ] && [ -n "$is_relative" ] || {
        print_error 'Failed to get the value of the Path or IsRelative key' \
            'from the selected Firefox profile section.'
        return "${_EX_DATAERR:?}"
    }
    if [ "$is_relative" = 1 ]; then
        dir_name=$(dirname -- "$profiles_ini") &&
            path=${dir_name%/}/$path || {
            print_error 'Failed to convert the selected Firefox profile path' \
                'from relative to absolute.'
            return "${_EX_DATAERR:?}"
        }
    fi
    printf '%s\n' "$path"
}

arkenfox_select_firefox_profile() { # arg: profiles.ini
    while :; do
        # Adapted from https://unix.stackexchange.com/a/786827.
        profiles=$(
            # Character classes and range expressions are locale-dependent:
            # https://unix.stackexchange.com/a/654391.
            awk -- '/^[[]/ { section = substr($0, 1) }
                    (section ~ /^[[]Profile[0123456789]+[]]$/) { print }' "$1"
        ) &&
            profile_count=$(
                printf '%s' "$profiles" |
                    grep -Ec '^[[]Profile[0123456789]+[]]$'
            ) &&
            is_integer "$profile_count" && [ "$profile_count" -gt 0 ] || {
            print_error 'Failed to find the profile sections in the INI file.'
            return "${_EX_DATAERR:?}"
        }
        if [ "$profile_count" -eq 1 ]; then
            printf '%s\n' "$profiles"
            return
        else
            display_profiles=$(
                printf '%s\n\n' "$profiles" |
                    grep -Ev -e '^IsRelative=' -e '^Default=' &&
                    awk -- '/^[[]/ { section = substr($0, 2) }
                            ((section ~ /^Install/) && /^Default=/) { print }' \
                        "$1"
            ) || return
            cat >&2 <<EOF
Profiles found:
––––––––––––––––––––––––––––––
$display_profiles
––––––––––––––––––––––––––––––
EOF
            print_info 'Select the profile number' \
                '(0 for Profile0, 1 for Profile1, etc; q to quit): '
            read -r REPLY || return
            print_info '\n'
            if is_integer "$REPLY" && [ "$REPLY" -ge 0 ]; then
                selected_profile=$(
                    printf '%s\n' "$profiles" |
                        awk -v select="$REPLY" \
                            'BEGIN { regex = "^[[]Profile"select"[]]$" }
                                     /^[[]/ { section = substr($0, 1) }
                                     section ~ regex { print }'
                ) &&
                    [ -n "$selected_profile" ] &&
                    printf '%s\n' "$selected_profile" &&
                    return ||
                    print_warning "Invalid profile number: $REPLY."
            elif [ "$REPLY" = 'Q' ] || [ "$REPLY" = 'q' ]; then
                return "${_EX_FAIL:?}"
            else
                print_warning 'Invalid input: not a whole number.'
            fi
        fi
    done
}

arkenfox_script_version() { # arg: {updater.sh|prefsCleaner.sh}
    version_format='[0123456789]\{1,\}\.[0123456789]\{1,\}' &&
        version=$(
            sed -n -- "5s/.*version:[[:blank:]]*\($version_format\).*/\1/p" "$1"
        ) &&
        [ -n "$version" ] &&
        printf '%s\n' "$version" || {
        print_error "Failed to determine the version of the script file: $1."
        return "${_EX_DATAERR:?}"
    }
}

arkenfox_userjs_version() { # arg: user.js
    sed -n -- '4p' "$1" || echo 'Unknown'
}

# Restore the starting sh options.
eval "$_ARKENFOX_STARTING_SHOPTS" &&
    # The above command fails to restore the errexit shell option in oksh.
    # Related: https://unix.stackexchange.com/q/523098.
    # Workaround for oksh:
    case $_ARKENFOX_STARTING_SHOPTS in
        *'set -o errexit'*) set -o errexit ;;
        *'set +o errexit'*) set +o errexit ;;
    esac ||
    return 2>/dev/null || exit

###############################################################################
####                 === updater.sh specific functions ===                 ####
###############################################################################

# Detect spoofing by external, readonly functions.
set -o errexit || return 2>/dev/null || exit

arkenfox_updater_init() {
    probe_terminal && probe_realpath_ "$REALPATH__IMPLEMENTATION" || return
    # IMPORTANT! ARKENFOX_UPDATER_NAME must be synced to the name of this file!
    # This is so that we may somewhat determine if the script is sourced or not
    # by comparing it to the basename of the canonical path of $0,
    # which should be better than hard coding all the names of
    # the interactive and non-interactive POSIX shells in existence.
    # Cf. https://stackoverflow.com/a/28776166.
    ARKENFOX_UPDATER_NAME=${ARKENFOX_UPDATER_NAME:-updater.sh} || return
    path=$(realpath_ "$0") &&
        dir_name=$(dirname -- "$path") &&
        base_name=$(basename -- "$path") || {
        print_error 'Failed to resolve the run file path.'
        return "${_EX_UNAVAILABLE:?}"
    }
    (
        _ARKENFOX_UPDATER_RUN_PATH=$path &&
            _ARKENFOX_UPDATER_RUN_DIR=$dir_name &&
            _ARKENFOX_UPDATER_RUN_NAME=$base_name
    ) 2>/dev/null &&
        _ARKENFOX_UPDATER_RUN_PATH=$path &&
        _ARKENFOX_UPDATER_RUN_DIR=$dir_name &&
        _ARKENFOX_UPDATER_RUN_NAME=$base_name &&
        readonly _ARKENFOX_UPDATER_RUN_PATH \
            _ARKENFOX_UPDATER_RUN_DIR \
            _ARKENFOX_UPDATER_RUN_NAME || {
        [ "$_ARKENFOX_UPDATER_RUN_PATH" = "$path" ] &&
            [ "$_ARKENFOX_UPDATER_RUN_DIR" = "$dir_name" ] &&
            [ "$_ARKENFOX_UPDATER_RUN_NAME" = "$base_name" ] || {
            print_error 'Failed to make the resolved run file path readonly.' \
                'Try again in a new shell environment?'
            return "${_EX_TEMPFAIL:?}"
        }
    }
}

arkenfox_updater() { # args: [options]
    arkenfox_updater_parse_options "$@" &&
        arkenfox_updater_probe_utilities || return
    arkenfox_updater_exec_general_options || {
        status=$? || return
        # An exit status of _EX__BASE indicates that a command tied to
        # a general option has been executed successfully.
        [ "$status" -eq "${_EX__BASE:?}" ] &&
            return "${_EX_OK:?}" ||
            return "$status"
    }
    arkenfox_updater_set_profile_path &&
        arkenfox_updater_check_nonroot &&
        arkenfox_updater_banner &&
        arkenfox_updater_update_self "$@" &&
        arkenfox_updater_update_userjs
}

arkenfox_updater_usage() {
    cat >&2 <<EOF

${_TPUT_AF_BLUE}Usage: ${ARKENFOX_UPDATER_NAME:?} [-h|-r]${_TPUT_SGR0}
${_TPUT_AF_BLUE}       ${ARKENFOX_UPDATER_NAME:?} [UPDATER_OPTION]... [USERJS_OPTION]...${_TPUT_SGR0}

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
    -o OVERRIDES Filename or path to overrides file (if different than user-overrides.js).
                 If used with -p, paths should be relative to PROFILE or absolute paths.
                 If given a directory, all files inside will be appended recursively.
                 You can pass multiple files or directories by passing a comma separated list.
                 Note: If a directory is given, only files inside ending in the extension .js are appended.
                 IMPORTANT: Do not add spaces between files/paths.  Ex: -o file1.js,file2.js,dir1
                 IMPORTANT: If any file/path contains spaces, wrap the entire argument in quotes.  Ex: -o "override folder"
    -v           Open the resulting user.js file.

EOF
}

arkenfox_updater_parse_options() { # args: [options]
    # OPTIND must be manually reset between multiple calls to getopts.
    OPTIND=1 &&
        _EXCLUSIVE_OPTIONS_COUNT=0 &&
        # IMPORTANT! Make sure to initialize all options!
        _ARKENFOX_UPDATER_OPTION_H_HELP= &&
        _ARKENFOX_UPDATER_OPTION_R_READ_ONLY= &&
        _ARKENFOX_UPDATER_OPTION_D_DONT_UPDATE= &&
        _ARKENFOX_UPDATER_OPTION_U_UPDATER_SILENT= &&
        _ARKENFOX_UPDATER_OPTION_P_PROFILE_PATH= &&
        _ARKENFOX_UPDATER_OPTION_L_LIST_FIREFOX_PROFILES= &&
        _ARKENFOX_UPDATER_OPTION_S_SILENT= &&
        _ARKENFOX_UPDATER_OPTION_C_COMPARE= &&
        _ARKENFOX_UPDATER_OPTION_B_BACKUP_SINGLE= &&
        _ARKENFOX_UPDATER_OPTION_E_ESR= &&
        _ARKENFOX_UPDATER_OPTION_N_NO_OVERRIDES= &&
        _ARKENFOX_UPDATER_OPTION_O_OVERRIDES= &&
        _ARKENFOX_UPDATER_OPTION_V_VIEW= ||
        return
    while getopts 'hrdup:lscbeno:v' opt; do
        [ "$_EXCLUSIVE_OPTIONS_COUNT" -eq 0 ] || {
            arkenfox_updater_usage
            return "${_EX_USAGE:?}"
        }
        case $opt in
            # General options
            h)
                _ARKENFOX_UPDATER_OPTION_H_HELP=1
                _EXCLUSIVE_OPTIONS_COUNT=1
                ;;
            r)
                _ARKENFOX_UPDATER_OPTION_R_READ_ONLY=1
                _EXCLUSIVE_OPTIONS_COUNT=1
                ;;
            # Updater options
            d) _ARKENFOX_UPDATER_OPTION_D_DONT_UPDATE=1 ;;
            u) _ARKENFOX_UPDATER_OPTION_U_UPDATER_SILENT=1 ;;
            # user.js options
            p) _ARKENFOX_UPDATER_OPTION_P_PROFILE_PATH=$OPTARG ;;
            l) _ARKENFOX_UPDATER_OPTION_L_LIST_FIREFOX_PROFILES=1 ;;
            s) _ARKENFOX_UPDATER_OPTION_S_SILENT=1 ;;
            c) _ARKENFOX_UPDATER_OPTION_C_COMPARE=1 ;;
            b) _ARKENFOX_UPDATER_OPTION_B_BACKUP_SINGLE=1 ;;
            e) _ARKENFOX_UPDATER_OPTION_E_ESR=1 ;;
            n) _ARKENFOX_UPDATER_OPTION_N_NO_OVERRIDES=1 ;;
            o) _ARKENFOX_UPDATER_OPTION_O_OVERRIDES=$OPTARG ;;
            v) _ARKENFOX_UPDATER_OPTION_V_VIEW=1 ;;
            \?)
                arkenfox_updater_usage
                return "${_EX_USAGE:?}"
                ;;
            :) return "${_EX_USAGE:?}" ;;
        esac
    done
}

arkenfox_updater_probe_utilities() {
    ! is_option_set "$_ARKENFOX_UPDATER_OPTION_H_HELP" || return "${_EX_OK:?}"
    probe_mktemp_ "$MKTEMP__IMPLEMENTATION" &&
        probe_wget_ "$WGET__IMPLEMENTATION" &&
        if is_option_set "$_ARKENFOX_UPDATER_OPTION_R_READ_ONLY" ||
            is_option_set "$_ARKENFOX_UPDATER_OPTION_V_VIEW"; then
            probe_open_ "$OPEN__IMPLEMENTATION"
        fi
}

arkenfox_updater_set_profile_path() {
    if [ -n "$_ARKENFOX_UPDATER_OPTION_P_PROFILE_PATH" ]; then
        _ARKENFOX_PROFILE_PATH=$_ARKENFOX_UPDATER_OPTION_P_PROFILE_PATH
    elif is_option_set "$_ARKENFOX_UPDATER_OPTION_L_LIST_FIREFOX_PROFILES"; then
        _ARKENFOX_PROFILE_PATH=$(arkenfox_select_firefox_profile_path)
    else
        _ARKENFOX_PROFILE_PATH=${_ARKENFOX_UPDATER_RUN_DIR:?}
    fi &&
        _ARKENFOX_PROFILE_PATH=$(realpath_ "$_ARKENFOX_PROFILE_PATH") ||
        return
    [ -w "$_ARKENFOX_PROFILE_PATH" ] &&
        cd -- "$_ARKENFOX_PROFILE_PATH" || {
        print_error 'The path to your Firefox profile' \
            "('$_ARKENFOX_PROFILE_PATH') failed to be a directory to which" \
            'the user has both write and execute access.'
        return "${_EX_UNAVAILABLE:?}"
    }
    _ARKENFOX_PROFILE_USERJS=${_ARKENFOX_PROFILE_PATH%/}/user.js &&
        _ARKENFOX_PROFILE_USERJS_BACKUP_DIR=${_ARKENFOX_PROFILE_PATH%/}/userjs_backups &&
        _ARKENFOX_PROFILE_USERJS_DIFF_DIR=${_ARKENFOX_PROFILE_PATH%/}/userjs_diffs
}

arkenfox_updater_check_nonroot() {
    kernel=$(uname) || return
    # Haiku is a single-user operating system.
    [ "$kernel" != 'Haiku' ] || return "${_EX_OK:?}"
    uid=$(id -u) || return
    if is_integer "$uid" && [ "$uid" -eq 0 ]; then
        print_error "You shouldn't run this with elevated privileges" \
            '(such as with doas/sudo).'
        return "${_EX_USAGE:?}"
    fi
    root_owned_files=$(
        find -- "${_ARKENFOX_PROFILE_PATH:?}" \
            -path "${_ARKENFOX_PROFILE_PATH:?}/*" -prune -user 0 \( \
            -path "${_ARKENFOX_PROFILE_USERJS:?}" \
            -o -path "${_ARKENFOX_PROFILE_USERJS_BACKUP_DIR:?}" \
            -o -path "${_ARKENFOX_PROFILE_USERJS_DIFF_DIR:?}" \
            \) -print
    ) &&
        if [ -n "$root_owned_files" ]; then
            # \b is a backspace to keep the trailing newlines
            # from being stripped by command substitution.
            print_error 'It looks like this script' \
                'was previously run with elevated privileges.' \
                'Please change ownership of the following files' \
                'to your user and try again:' \
                "$(printf '%s\n\b' '')$root_owned_files"
            return "${_EX_CONFIG:?}"
        fi
}

arkenfox_updater_exec_general_options() {
    if is_option_set "$_ARKENFOX_UPDATER_OPTION_H_HELP"; then
        arkenfox_updater_usage 2>&1
    elif is_option_set "$_ARKENFOX_UPDATER_OPTION_R_READ_ONLY"; then
        arkenfox_updater_wget__open__userjs
    else
        return "${_EX_OK:?}"
    fi
    # We want to return from the caller function as well if a command tied to
    # a general option is executed.
    # To achieve that, we translate an exit status of _EX_OK to _EX__BASE
    # and handle the retranslation back to its original exit status
    # in the caller function.
    status=$? || return
    if [ "$status" -eq "${_EX_OK:?}" ]; then
        return "${_EX__BASE:?}"
    # If the command itself exits with status code _EX__BASE (64),
    # we change it to an exit status unused by all of curl, wget and fetch,
    # which happens to be the meaningful _EX_PROTOCOL (76):
    # https://everything.curl.dev/cmdline/exitcode.html
    # https://www.gnu.org/software/wget/manual/html_node/Exit-Status.html
    # https://man.freebsd.org/cgi/man.cgi?query=fetch&apropos=0&sektion=1&manpath=FreeBSD+14.2-RELEASE&arch=default&format=html#EXIT_STATUS
    elif [ "$status" -eq "${_EX__BASE:?}" ]; then
        return "${_EX_PROTOCOL:?}"
    else
        return "$status"
    fi
}

arkenfox_updater_wget__open__userjs() {
    temp=$(
        download_file \
            'https://raw.githubusercontent.com/arkenfox/user.js/master/user.js'
    ) &&
        downloaded_userjs=$temp.js &&
        # Suppress diagnostic message on FreeBSD/DragonFly
        # (mv: set owner/group: Operation not permitted).
        mv -f -- "$temp" "$downloaded_userjs" 2>/dev/null &&
        print_ok 'user.js was saved to the temporary file:' \
            "$downloaded_userjs." &&
        open_ "$downloaded_userjs"
}

arkenfox_updater_banner() {
    cat >&2 <<EOF
${_TPUT_BOLD_AF_BLUE}
##############################################################################
####                                                                      ####
####                           arkenfox user.js                           ####
####        Hardening the Privacy and Security Settings of Firefox        ####
####            Maintained by @Thorin-Oakenpants and @earthlng            ####
####             Updater for macOS and Linux by @overdodactyl             ####
####                                                                      ####
##############################################################################
${_TPUT_SGR0}

Documentation for this script is available here:${_TPUT_AF_CYAN}
https://github.com/arkenfox/user.js/wiki/5.1-Updater-%5BOptions%5D#-maclinux
${_TPUT_SGR0}
EOF
}

arkenfox_updater_update_self() { # args: [options]
    ! is_option_set "$_ARKENFOX_UPDATER_OPTION_D_DONT_UPDATE" || return "${_EX_OK:?}"
    local_updater=${_ARKENFOX_UPDATER_RUN_PATH:?} &&
        downloaded_updater=$(
            download_file \
                'https://raw.githubusercontent.com/arkenfox/user.js/master/updater.sh'
        ) ||
        return
    local_version=$(arkenfox_script_version "$local_updater") &&
        downloaded_version=$(arkenfox_script_version "$downloaded_updater") &&
        local_major_version=${local_version%%.*} &&
        is_integer "$local_major_version" &&
        local_minor_version=${local_version#*.} &&
        is_integer "$local_minor_version" &&
        downloaded_major_version=${downloaded_version%%.*} &&
        is_integer "$downloaded_major_version" &&
        downloaded_minor_version=${downloaded_version#*.} &&
        is_integer "$downloaded_minor_version" || {
        print_error 'Failed to obtain valid version parts for comparison.'
        return "${_EX_DATAERR:?}"
    }
    if [ "$local_major_version" -eq "$downloaded_major_version" ] &&
        [ "$local_minor_version" -lt "$downloaded_minor_version" ] ||
        [ "$local_major_version" -lt "$downloaded_major_version" ]; then
        if ! is_option_set "$_ARKENFOX_UPDATER_OPTION_U_UPDATER_SILENT"; then
            print_info 'There is a newer version of updater.sh available. '
            print_yN 'Update and execute?'
            read1 REPLY || return
            print_info '\n\n'
            [ "$REPLY" = 'Y' ] || [ "$REPLY" = 'y' ] || return "${_EX_OK:?}"
        fi
        # Suppress diagnostic message on FreeBSD/DragonFly
        # (mv: set owner/group: Operation not permitted).
        mv -f -- "$downloaded_updater" "$local_updater" 2>/dev/null &&
            chmod -- u+rx "$local_updater" || {
            print_error 'Failed to update the arkenfox user.js updater' \
                'and make it executable.'
            return "${_EX_CANTCREAT:?}"
        }
        "$local_updater" -d "$@"
    fi
}

arkenfox_updater_update_userjs() {
    userjs=${_ARKENFOX_PROFILE_USERJS:?} &&
        downloaded_userjs=$(
            download_file \
                'https://raw.githubusercontent.com/arkenfox/user.js/master/user.js'
        ) &&
        local_version=$(arkenfox_userjs_version "$userjs") &&
        downloaded_version=$(arkenfox_userjs_version "$downloaded_userjs") ||
        return
    cat >&2 <<EOF

Please observe the following information:
    Firefox profile:  ${_TPUT_AF_YELLOW}${_ARKENFOX_PROFILE_PATH:?}${_TPUT_SGR0}
    Available online: ${_TPUT_AF_YELLOW}$downloaded_version${_TPUT_SGR0}
    Currently using:  ${_TPUT_AF_YELLOW}$local_version${_TPUT_SGR0}


EOF
    if ! is_option_set "$_ARKENFOX_UPDATER_OPTION_S_SILENT"; then
        print_info 'This script will update to the latest user.js file' \
            'and apply any custom configurations' \
            'from the supplied user-overrides.js files. '
        print_yN 'Continue?'
        read1 REPLY || return
        print_info '\n\n'
        [ "$REPLY" = 'Y' ] || [ "$REPLY" = 'y' ] || {
            print_error 'Process aborted!'
            return "${_EX_FAIL:?}"
        }
    fi
    if [ -e "$userjs" ]; then
        userjs_backup=$(arkenfox_updater_backup_userjs "$userjs")
    fi &&
        # Suppress diagnostic message on FreeBSD/DragonFly
        # (mv: set owner/group: Operation not permitted).
        mv -f -- "$downloaded_userjs" "$userjs" 2>/dev/null ||
        return
    print_ok 'user.js has been backed up' \
        'and replaced with the latest version!'
    arkenfox_updater_customize_userjs "$userjs" || return
    if is_option_set "$_ARKENFOX_UPDATER_OPTION_C_COMPARE" &&
        [ -e "$userjs_backup" ]; then
        diff_file=$(arkenfox_updater_diff_userjs "$userjs" "$userjs_backup")
        status=$? && {
            [ "$status" -eq "${_EX_OK:?}" ] || [ "$status" -eq "${_EX_FAIL:?}" ]
        } ||
            return
        if [ -n "$diff_file" ]; then
            print_ok "A diff file was created: $diff_file."
        else
            print_warning 'Your new user.js file appears to be identical.' \
                'No diff file was created.'
        fi
    fi
    ! is_option_set "$_ARKENFOX_UPDATER_OPTION_V_VIEW" || open_ "$userjs"
}

arkenfox_updater_backup_userjs() { # arg: user.js
    backup_dir=${_ARKENFOX_PROFILE_USERJS_BACKUP_DIR:?} &&
        if is_option_set "$_ARKENFOX_UPDATER_OPTION_B_BACKUP_SINGLE"; then
            userjs_backup=$backup_dir/user.js.backup
        else
            userjs_backup=$backup_dir/user.js.backup.$(date +"%Y-%m-%d_%H%M")
        fi &&
        # Add the -p option so that mkdir does not return a >0 exit status
        # if any of the specified directories already exists.
        mkdir -p -- "$backup_dir" &&
        cp -f -- "$1" "$userjs_backup" &&
        printf '%s\n' "$userjs_backup"
}

arkenfox_updater_customize_userjs() { # arg: user.js
    if is_option_set "$_ARKENFOX_UPDATER_OPTION_E_ESR"; then
        temp=$(mktemp_) &&
            sed -- \
                's/\/\* \(ESR[0123456789]\{2,\}\.x still uses all.*\)/\/\/ \1/' \
                "$1" >|"$temp" &&
            # Suppress diagnostic message on FreeBSD/DragonFly
            # (mv: set owner/group: Operation not permitted).
            mv -f -- "$temp" "$1" 2>/dev/null &&
            print_ok 'ESR related preferences have been activated!' ||
            return
    fi
    if ! is_option_set "$_ARKENFOX_UPDATER_OPTION_N_NO_OVERRIDES"; then
        if [ -n "$_ARKENFOX_UPDATER_OPTION_O_OVERRIDES" ]; then
            overrides=$_ARKENFOX_UPDATER_OPTION_O_OVERRIDES
        else
            overrides=${_ARKENFOX_PROFILE_PATH:?}/user-overrides.js
        fi && (
            # "Double quote to prevent globbing and word splitting."
            # shellcheck disable=SC2086
            IFS=, &&
                set -o noglob &&
                arkenfox_updater_append_userjs_overrides $overrides
        )
    fi
}

arkenfox_updater_append_userjs_overrides() { # args: FILE...
    override= || return
    while [ "$#" -gt 0 ]; do
        override=$(realpath_ "$1") &&
            if [ -f "$override" ]; then
                # Using an interim temp file ensures that the whole override file
                # is appended and allows appending the user.js file to itself.
                # The side effect is that the file permissions of the new user.js
                # may be different from before, but this should not be a concern.
                temp=$(mktemp_) &&
                    cat -- "${_ARKENFOX_PROFILE_USERJS:?}" >|"$temp" &&
                    echo >>"$temp" &&
                    cat -- "$override" >>"$temp" &&
                    # Suppress diagnostic message on FreeBSD/DragonFly
                    # (mv: set owner/group: Operation not permitted).
                    mv -f -- "$temp" \
                        "${_ARKENFOX_PROFILE_USERJS:?}" 2>/dev/null &&
                    print_ok "Override file appended: $override." || {
                    print_error "Failed to append override file: $override."
                    return "${_EX_UNAVAILABLE}"
                }
            elif [ -d "$override" ]; then
                (
                    set +o noglob &&
                        set -- "$override"/*.js &&
                        while [ "$#" -gt 0 ]; do
                            arkenfox_updater_append_userjs_overrides "$1" ||
                                exit
                            shift
                        done
                )
            else
                ! :
            fi ||
            print_warning "Could not find override file: ${override:-$1}."
        shift
    done
}

arkenfox_updater_diff_userjs() { # args: FILE1 FILE2
    diff_dir=${_ARKENFOX_PROFILE_USERJS_DIFF_DIR:?} &&
        # Add the -p option so that mkdir does not return a >0 exit status
        # if any of the specified directories already exists.
        mkdir -p -- "$diff_dir" &&
        old_userjs_stripped=$(mktemp_) &&
        new_userjs_stripped=$(mktemp_) &&
        arkenfox_remove_userjs_comments "$2" >|"$old_userjs_stripped" &&
        arkenfox_remove_userjs_comments "$1" >|"$new_userjs_stripped" ||
        return
    diff=$(diff -b -U 0 -- "$old_userjs_stripped" "$new_userjs_stripped")
    status=$? || return
    # OpenIndiana's diff -U may output "No differences encountered".
    if [ -n "$diff" ] && [ "$status" -eq "${_EX_FAIL:?}" ]; then
        diff_file=$diff_dir/diff_$(date +"%Y-%m-%d_%H%M").txt &&
            temp=$(mktemp_) &&
            printf '%s\n' "$diff" |
            sed -e "1s|\($old_userjs_stripped\)|\1 (old user.js)|" \
                -e "2s|\($new_userjs_stripped\)|\1 (new user.js)|" \
                >|"$temp" &&
            # Suppress diagnostic message on FreeBSD/DragonFly
            # (mv: set owner/group: Operation not permitted).
            mv -f -- "$temp" "$diff_file" 2>/dev/null &&
            printf '%s\n' "$diff_file" ||
            return
    fi
    return "$status"
}

# Restore the starting sh options.
eval "$_ARKENFOX_STARTING_SHOPTS" || return 2>/dev/null || exit
# The above command fails to restore the errexit shell option in oksh.
# Related: https://unix.stackexchange.com/q/523098.
# Workaround for oksh:
case $_ARKENFOX_STARTING_SHOPTS in
    *'set -o errexit'*) set -o errexit ;;
    *'set +o errexit'*) set +o errexit ;;
esac

# "Command appears to be unreachable. Check usage (or ignore if invoked indirectly)."
# shellcheck disable=SC2317
(main() { :; }) && : # For quick navigation in IDEs only.
init && arkenfox_updater_init
status=$? &&
    if [ "$status" -eq 0 ]; then
        if [ "${_ARKENFOX_UPDATER_RUN_NAME:?}" = "${ARKENFOX_UPDATER_NAME:?}" ]; then
            arkenfox_updater "$@"
        else
            print_ok 'The arkenfox user.js updater script' \
                'has been successfully sourced.'
            print_warning 'If this is not intentional,' \
                'you may have either made a typo in the shell commands,' \
                'or renamed this file without defining the environment variable' \
                'ARKENFOX_UPDATER_NAME to match the new name.' \
                "

         Detected name of the run file: ${_ARKENFOX_UPDATER_RUN_NAME:?}
         ARKENFOX_UPDATER_NAME        : ${ARKENFOX_UPDATER_NAME:?}
" \
                "$(printf '%s\n\b' '')Please note that this is not" \
                'the expected way to run the arkenfox user.js updater script.' \
                'Dot sourcing support is experimental' \
                'and all function and variable names are still subject to change.'
            # Make arkenfox_updater_update_self a no-op as this function
            # can not be run reliably when dot-sourced.
            eval 'arkenfox_updater_update_self() { :; }'
        fi
    else
        # '&& :' to avoid exiting the shell if the shell option errexit is set.
        (exit "$status") && :
    fi
