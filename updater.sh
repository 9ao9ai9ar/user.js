#!/bin/sh

## arkenfox user.js updater for macOS and Linux

## version: 4.1
## Author: Pat Johnson (@overdodactyl)
## Additional contributors: @earthlng, @ema-pe, @claustromaniac, @infinitewarp, @9ao9ai9ar

## DON'T GO HIGHER THAN VERSION x.9 !! ( because of ASCII comparison in update_updater() )
## ^Should be fixed with version 4.1.
## Just make sure the version is of the format major.minor and within the first five lines ( because of the way the sed script is written ).

# Check if running as root
if [ "$(id -u)" -eq 0 ]; then
    printf "You shouldn't run this with elevated privileges (such as with doas/sudo).\n"
    exit 1
fi

readonly CURRDIR=$(pwd)

## get the full path of this script (readlink for Linux and macOS 12.3+, greadlink for Mac with coreutils installed)
# https://stackoverflow.com/q/29832037: rewriting ${BASH_SOURCE[0]} as $0 only works if script is not sourced.
SCRIPT_FILE=$(readlink -f -- "$0" 2>/dev/null || greadlink -f -- "$0" 2>/dev/null)
## fallback for Macs without coreutils
[ -z "$SCRIPT_FILE" ] && SCRIPT_FILE=$0
readonly SCRIPT_DIR=$(dirname "${SCRIPT_FILE}")

#########################
#    Base variables     #
#########################

# Colors used for printing
if tput setaf >/dev/null && tput sgr0 >/dev/null; then
    RED=$(tput setaf 1)
    BLUE=$(tput setaf 4)
    BBLUE="$(tput bold)$(tput setaf 4)"
    GREEN=$(tput setaf 2)
    ORANGE=$(tput setaf 3)
    CYAN=$(tput setaf 6)
    NC=$(tput sgr0) # No Color
fi

# Argument defaults
UPDATE='check'
CONFIRM='yes'
OVERRIDE='user-overrides.js'
BACKUP='multiple'
COMPARE=false
SKIPOVERRIDE=false
VIEW=false
PROFILE_PATH=false
ESR=false

# Download method priority: curl -> wget
DOWNLOAD_METHOD=''
if command -v curl >/dev/null; then
    DOWNLOAD_METHOD='curl --max-redirs 3 -so'
elif command -v wget >/dev/null; then
    DOWNLOAD_METHOD='wget --max-redirect 3 --quiet -O'
else
    printf "${RED}This script requires curl or wget.\nProcess aborted${NC}\n"
    exit 1
fi

show_banner() {
    printf "${BBLUE}
                ############################################################################
                ####                                                                    ####
                ####                          arkenfox user.js                          ####
                ####       Hardening the Privacy and Security Settings of Firefox       ####
                ####           Maintained by @Thorin-Oakenpants and @earthlng           ####
                ####            Updater for macOS and Linux by @overdodactyl            ####
                ####                                                                    ####
                ############################################################################\n"
    printf "${NC}\n\n"
    printf "Documentation for this script is available here: ${CYAN}https://github.com/arkenfox/user.js/wiki/5.1-Updater-[Options]#-maclinux${NC}\n\n"
}

#########################
#      Arguments        #
#########################

usage() {
    echo
    printf "${BLUE}Usage: $0 [-bcdehlnrsuv] [-p PROFILE] [-o OVERRIDE]${NC}\n" 1>&2 # Echo usage string to standard error
    printf "
Optional Arguments:
    -h           Show this help message and exit.
    -p PROFILE   Path to your Firefox profile (if different than the dir of this script)
                 IMPORTANT: If the path contains spaces, wrap the entire argument in quotes.
    -l           Choose your Firefox profile from a list
    -u           Update updater.sh and execute silently.  Do not seek confirmation.
    -d           Do not look for updates to updater.sh.
    -s           Silently update user.js.  Do not seek confirmation.
    -b           Only keep one backup of each file.
    -c           Create a diff file comparing old and new user.js within userjs_diffs.
    -o OVERRIDE  Filename or path to overrides file (if different than user-overrides.js).
                 If used with -p, paths should be relative to PROFILE or absolute paths
                 If given a directory, all files inside will be appended recursively.
                 You can pass multiple files or directories by passing a comma separated list.
                     Note: If a directory is given, only files inside ending in the extension .js are appended
                     IMPORTANT: Do not add spaces between files/paths.  Ex: -o file1.js,file2.js,dir1
                     IMPORTANT: If any file/path contains spaces, wrap the entire argument in quotes.
                         Ex: -o \"override folder\"
    -n           Do not append any overrides, even if user-overrides.js exists.
    -v           Open the resulting user.js file.
    -r           Only download user.js to a temporary file and open it.
    -e           Activate ESR related preferences.\n"
    echo
    exit 1
}

#########################
#     File Handling     #
#########################

download_file() { # expects URL as argument ($1)
    readonly tf=$(mktemp)

    $DOWNLOAD_METHOD "${tf}" "$1" >/dev/null 2>&1 && echo "$tf" || echo '' # return the temp-filename or empty string on error
}

open_file() { # expects one argument: file_path
    if [ "$(uname)" = 'Darwin' ]; then
        open "$1"
    elif [ "$(uname -s | cut -c -5)" = "Linux" ]; then
        xdg-open "$1"
    else
        printf "${RED}Error: Sorry, opening files is not supported for your OS.${NC}\n"
    fi
}

readIniFile() { # expects one argument: absolute path of profiles.ini
    readonly inifile="$1"

    # tempIni will contain: [ProfileX], Name=, IsRelative= and Path= (and Default= if present) of the only (if) or the selected (else) profile
    if [ "$(grep -c '^\[Profile' "${inifile}")" -eq "1" ]; then ### only 1 profile found
        tempIni="$(grep '^\[Profile' -A 4 "${inifile}")"
    else
        printf "Profiles found:\n––––––––––––––––––––––––––––––\n"
        ## cmd-substitution to strip trailing newlines and in quotes to keep internal ones:
        echo "$(grep --color=never -E 'Default=[^1]|\[Profile[0-9]*\]|Name=|Path=|^$' "${inifile}")"
        echo '––––––––––––––––––––––––––––––'
        echo 'Select the profile number ( 0 for Profile0, 1 for Profile1, etc ) : ' >&2
        read -r REPLY
        printf "\n\n"
        case "$REPLY" in
            0 | [1-9] | [1-9][0-9]*)
                tempIni="$(grep "^\[Profile${REPLY}" -A 4 "${inifile}")" || {
                    printf "${RED}Profile${REPLY} does not exist!${NC}\n" && exit 1
                }
                ;;
            *)
                printf "${RED}Invalid selection!${NC}\n" && exit 1
                ;;
        esac
    fi

    # extracting 0 or 1 from the "IsRelative=" line
    readonly pathisrel=$(
        sed -n 's/^IsRelative=\([01]\)$/\1/p' <<EOF
${tempIni}
EOF
    )

    # extracting only the path itself, excluding "Path="
    PROFILE_PATH=$(
        sed -n 's/^Path=\(.*\)$/\1/p' <<EOF
${tempIni}
EOF
    )
    # update global variable if path is relative
    [ "${pathisrel}" = "1" ] && PROFILE_PATH="$(dirname "${inifile}")/${PROFILE_PATH}"
}

getProfilePath() {
    readonly f1=~/Library/Application\ Support/Firefox/profiles.ini
    readonly f2=~/.mozilla/firefox/profiles.ini

    if [ "$PROFILE_PATH" = false ]; then
        PROFILE_PATH="$SCRIPT_DIR"
    elif [ "$PROFILE_PATH" = 'list' ]; then
        if [ -f "$f1" ]; then
            readIniFile "$f1" # updates PROFILE_PATH or exits on error
        elif [ -f "$f2" ]; then
            readIniFile "$f2"
        else
            printf "${RED}Error: Sorry, -l is not supported for your OS${NC}\n"
            exit 1
        fi
        #else
        # PROFILE_PATH already set by user with -p
    fi
}

#########################
#   Update updater.sh   #
#########################

# Returns the version number of a updater.sh file
get_updater_version() {
    echo "$(sed -n '5 s/.*[[:blank:]]\([[:digit:]]*\.[[:digit:]]*\)/\1/p' "$1")"
}

# read -rN 1 equivalent in POSIX shell: https://unix.stackexchange.com/a/464963
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

# Update updater.sh
# Default: Check for update, if available, ask user if they want to execute it
# Args:
#   -d: New version will not be looked for and update will not occur
#   -u: Check for update, if available, execute without asking
update_updater() {
    [ "$UPDATE" = 'no' ] && return 0 # User signified not to check for updates

    readonly tmpfile="$(download_file 'https://raw.githubusercontent.com/arkenfox/user.js/master/updater.sh')"
    [ -z "${tmpfile}" ] && printf "${RED}Error! Could not download updater.sh${NC}\n" && return 1 # check if download failed

    local_version=$(get_updater_version "$SCRIPT_FILE")
    remote_version=$(get_updater_version "${tmpfile}")
    if [ ${local_version%.*} -eq ${remote_version%.*} ] && [ ${local_version#*.} -lt ${remote_version#*.} ] ||
        [ ${local_version%.*} -lt ${remote_version%.*} ]; then
        if [ "$UPDATE" = 'check' ]; then
            printf "There is a newer version of updater.sh available. ${RED}Update and execute Y/N?${NC}\n"
            read1 REPLY
            printf "\n\n\n"
            [ "$REPLY" != "Y" ] && [ "$REPLY" != "y" ] && return 0 # Update available, but user chooses not to update
        fi
    else
        return 0 # No update available
    fi
    mv "${tmpfile}" "$SCRIPT_FILE"
    chmod u+x "$SCRIPT_FILE"
    "$SCRIPT_FILE" "$@" -d
    exit 0
}

#########################
#    Update user.js     #
#########################

# Returns version number of a user.js file
get_userjs_version() {
    [ -e "$1" ] && echo "$(sed -n '4p' "$1")" || echo "Not detected."
}

add_override() {
    input=$1
    if [ -f "$input" ]; then
        echo "" >>user.js
        cat "$input" >>user.js
        printf "Status: ${GREEN}Override file appended:${NC} ${input}\n"
    elif [ -d "$input" ]; then
        SAVEIFS=$IFS
        IFS=$(printf '\n\b')
        FILES="${input}"/*.js
        for f in $FILES; do
            add_override "$f"
        done
        IFS=$SAVEIFS # restore $IFS
    else
        printf "${ORANGE}Warning: Could not find override file:${NC} ${input}\n"
    fi
}

remove_comments() { # expects 2 arguments: from-file and to-file
    sed -e '/^\/\*.*\*\/[[:space:]]*$/d' -e '/^\/\*/,/\*\//d' -e 's|^[[:space:]]*//.*$||' -e '/^[[:space:]]*$/d' -e 's|);[[:space:]]*//.*|);|' "$1" >"$2"
}

# Applies latest version of user.js and any custom overrides
update_userjs() {
    readonly newfile="$(download_file 'https://raw.githubusercontent.com/arkenfox/user.js/master/user.js')"
    [ -z "${newfile}" ] && printf "${RED}Error! Could not download user.js${NC}\n" && return 1 # check if download failed

    printf "Please observe the following information:
    Firefox profile:  ${ORANGE}$(pwd)${NC}
    Available online: ${ORANGE}$(get_userjs_version "$newfile")${NC}
    Currently using:  ${ORANGE}$(get_userjs_version user.js)${NC}\n\n\n"

    if [ "$CONFIRM" = 'yes' ]; then
        printf "This script will update to the latest user.js file and append any custom configurations from user-overrides.js. ${RED}Continue Y/N? ${NC}\n"
        read1 REPLY
        printf "\n\n"
        if [ "$REPLY" != "Y" ] && [ "$REPLY" != "y" ]; then
            printf "${RED}Process aborted${NC}\n"
            rm "$newfile"
            return 1
        fi
    fi

    # Copy a version of user.js to diffs folder for later comparison
    if [ "$COMPARE" = true ]; then
        mkdir -p userjs_diffs
        cp user.js userjs_diffs/past_user.js >/dev/null 2>&1
    fi

    # backup user.js
    mkdir -p userjs_backups
    bakname="userjs_backups/user.js.backup.$(date +"%Y-%m-%d_%H%M")"
    [ "$BACKUP" = 'single' ] && bakname='userjs_backups/user.js.backup'
    cp user.js "$bakname" >/dev/null 2>&1

    mv "${newfile}" user.js
    printf "Status: ${GREEN}user.js has been backed up and replaced with the latest version!${NC}\n"

    if [ "$ESR" = true ]; then
        sed -e 's/\/\* \(ESR[0-9]\{2,\}\.x still uses all.*\)/\/\/ \1/' user.js >user.js.tmp && mv user.js.tmp user.js
        printf "Status: ${GREEN}ESR related preferences have been activated!${NC}\n"
    fi

    # apply overrides
    if ! [ "$SKIPOVERRIDE" ]; then
        IFS=,
        for FILE in $OVERRIDE; do
            add_override "$FILE"
        done
        unset IFS
    fi

    # create diff
    if [ "$COMPARE" = true ]; then
        pastuserjs='userjs_diffs/past_user.js'
        past_nocomments='userjs_diffs/past_userjs.txt'
        current_nocomments='userjs_diffs/current_userjs.txt'

        remove_comments "$pastuserjs" "$past_nocomments"
        remove_comments user.js "$current_nocomments"

        diffname="userjs_diffs/diff_$(date +"%Y-%m-%d_%H%M").txt"
        diff=$(diff -w -B -U 0 "$past_nocomments" "$current_nocomments")
        if [ -n "$diff" ]; then
            echo "$diff" >"$diffname"
            printf "Status: ${GREEN}A diff file was created:${NC} ${PWD}/${diffname}\n"
        else
            printf "Warning: ${ORANGE}Your new user.js file appears to be identical.  No diff file was created.${NC}\n"
            [ "$BACKUP" = 'multiple' ] && rm "$bakname" >/dev/null 2>&1
        fi
        rm "$past_nocomments" "$current_nocomments" "$pastuserjs" >/dev/null 2>&1
    fi

    [ "$VIEW" = true ] && open_file "${PWD}/user.js"
}

#########################
#        Execute        #
#########################

if [ $# != 0 ]; then
    # Display usage if first argument is -help or --help
    if [ "$1" = '--help' ] || [ "$1" = '-help' ]; then
        usage
    else
        while getopts ":hp:ludsno:bcvre" opt; do
            case $opt in
                h)
                    usage
                    ;;
                p)
                    PROFILE_PATH=${OPTARG}
                    ;;
                l)
                    PROFILE_PATH='list'
                    ;;
                u)
                    UPDATE='yes'
                    ;;
                d)
                    UPDATE='no'
                    ;;
                s)
                    CONFIRM='no'
                    ;;
                n)
                    SKIPOVERRIDE=true
                    ;;
                o)
                    OVERRIDE=${OPTARG}
                    ;;
                b)
                    BACKUP='single'
                    ;;
                c)
                    COMPARE=true
                    ;;
                v)
                    VIEW=true
                    ;;
                e)
                    ESR=true
                    ;;
                r)
                    tfile="$(download_file 'https://raw.githubusercontent.com/arkenfox/user.js/master/user.js')"
                    [ -z "${tfile}" ] && printf "${RED}Error! Could not download user.js${NC}\n" && exit 1 # check if download failed
                    mv "$tfile" "${tfile}.js"
                    printf "${ORANGE}Warning: user.js was saved to temporary file ${tfile}.js${NC}\n"
                    open_file "${tfile}.js"
                    exit 0
                    ;;
                \?)
                    printf "${RED}\n Error! Invalid option: -$OPTARG${NC}\n" >&2
                    usage
                    ;;
                :)
                    printf "${RED}Error! Option -$OPTARG requires an argument.${NC}\n" >&2
                    exit 2
                    ;;
            esac
        done
    fi
fi

show_banner
update_updater "$@"

getProfilePath # updates PROFILE_PATH or exits on error
cd "$PROFILE_PATH" || exit 1

# Check if any files have the owner as root/wheel.
if [ -n "$(find ./ -user 0)" ]; then
    printf 'It looks like this script was previously run with elevated privileges,
you will need to change ownership of the following files to your user:\n'
    find . -user 0
    cd "$CURRDIR"
    exit 1
fi

update_userjs

cd "$CURRDIR"
