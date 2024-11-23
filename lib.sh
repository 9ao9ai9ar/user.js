#!/bin/sh

# https://stackoverflow.com/q/1101957
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
_EX_SIGHUP=129     # A command was interrupted by SIGHUP (1).
_EX_SIGINT=130     # A command was interrupted by SIGINT (2).
_EX_SIGQUIT=131    # A command was interrupted by SIGQUIT (3).
_EX_SIGABRT=134    # A command was interrupted by SIGABRT (6).
_EX_SIGKILL=137    # A command was interrupted by SIGKILL (9).
_EX_SIGALRM=142    # A command was interrupted by SIGALRM (14).
_EX_SIGTERM=143    # A command was interrupted by SIGTERM (15).
EOF
}
