#!/bin/bash
#verbose head


## settings
HEADLINES=3
USE_COLOURS=1
COLOUR_WEIGHT=1
STATIC_INDENT=1
DISTANCE=2
PROGRESS_BAR=1
#BUFFER_ALL_OUTPUT=1


## internals: here be dragons
_COLOUR_PREV=
_LONGEST_FILENAME=
_FILES=
_ORIG_NUM_FILES=


## functions
rotate_colour() {
    [[ $USE_COLOURS ]] || return
    [[ ${_COLOUR_PREV:-36} -gt 35 ]] && _COLOUR_PREV=31 || \
        _COLOUR_PREV=$((_COLOUR_PREV+1))
    get_colour_glyph $_COLOUR_PREV
}

get_colour_glyph() {
    [[ $USE_COLOURS ]] || return
    local colour clear
    case ${1:-0} in
        GREY|GRAY)  colour=30 ;;
        RED)        colour=31 ;;
        GREEN)      colour=32 ;;
        BROWN)      colour=33 ;;
        BLUE)       colour=34 ;;
        MAGENTA)    colour=35 ;;
        CYAN)       colour=36 ;;
        CLEAR)      clear=0   ;;
        [0-9][0-9]) colour=$1 ;; # could use pattern matching but needs extglob
        *)
            printf -- "err: unknown colour specified: %s\n" "$1" >&2
            return 1
            ;;
    esac
    printf -- "\033[${clear:-"${COLOUR_WEIGHT};$colour"}m"
}

reset_prev_colour() {
    [[ $USE_COLOURS ]] || return
    get_colour_glyph ${_COLOUR_PREV:=31}
}

in_clear() {
    [[ $USE_COLOURS ]] || return
    get_colour_glyph CLEAR
    printf -- "$@"
    reset_prev_colour
}

parse_genus() {
    # $1 number, $2 singular, $3 plural
    [[ $1 = 1 || $1 = -1 ]] && printf -- "$2" || printf -- "$3"
}

populate_array() {
    local IFS
    #TODO: support specifying by script arguments
    #_FILES=( * )
    _FILES=( ${@:-$(ls -A1)} )
    _ORIG_NUM_FILES=${#_FILES[@]}
}

prune_array() {
    local IFS _this newfiles
    [[ $PROGRESS_BAR ]] && printf -- "%${STATIC_INDENT}s" ""
    for _this in ${_FILES[@]}; do
        probe_file "$_this" || continue
        [[ $PROGRESS_BAR ]] && printf -- '.' >&2
        newfiles[${#newfiles[@]}]="$_this"
    done
    unset _FILES
    _FILES=( ${newfiles[@]} )
    [[ $PROGRESS_BAR ]] && printf -- '\n' #linebreak
}

probe_file() {
    local file
    file="$1"
    [[ ! -e "$file" ]] && return 1
    [[ -d "$file" ]] && _PROBED_DIRS=$((PROBED_DIRS+1)) && return 1
    cut -c1 &>/dev/null < "$file" || return 1
    case "$file" in
        *~|*.kate-swp) return 1 ;;
    esac
    case "$(file "$file")" in
        *text*|*": empty"*|*"very small file"*) return 0 ;;
        *) return 1 ;;
    esac
}

get_longest_filename() {
    local IFS
    IFS=$'\n'
    _LONGEST_FILENAME=$(wc -L <<< "${_FILES[*]}")
}

iterate_files() {
    local IFS _this lineno truncated pattern numlines head header _line
    IFS=$'\n'
    for _this in ${_FILES[@]}; do
        unset lineno truncated
        pattern="%${STATIC_INDENT}s%-$((_LONGEST_FILENAME+DISTANCE))s%2s%s\n"
        numlines=$(wc -l < "$_this")
        head="$(head -n$HEADLINES "$_this")"
        header="$_this"
        lineno=0
        rotate_colour
        while read _line; do
            lineno=$((lineno+1))
            [[ $numlines -eq 0 && ! $_line ]] && _line="$(in_clear "< empty >")"
            printf -- "$pattern" "" "$header" $lineno ": $_line"
            unset header
        done <<< "$head"
        truncated=$((numlines-HEADLINES))
        [[ ! $truncated -gt 0 ]] && continue
        truncline=" $(in_clear "[%d lines truncated]" $truncated)"
        #get_colour_glyph CLEAR
        printf -- "$pattern" "" "" "$truncline" ""
    done
}

summary() {
    local IFS listed_files skipped_dirs skipped_files string_numfiles
    local string_skip_files string_skip_dirs
    listed_files=${#_FILES[@]}
    skipped_dirs=${_PROBED_DIRS:=0}
    skipped_files=$((_ORIG_NUM_FILES-listed_files-_PROBED_DIRS))
    string_numfiles=$(parse_genus $listed_files file files)
    string_skip_files=$(parse_genus $skipped_files file files)
    string_skip_dirs=$(parse_genus $skipped_dirs directory directories)
    printf -- "\n%d %s listed, with %d %s and %d %s skipped\n" $listed_files \
        $string_numfiles $skipped_files $string_skip_files $skipped_dirs \
        $string_skip_dirs
}

main() {
    #printf -- "[profile] start:  %s\n" $(date "+%S%N") >&2
    populate_array "$@"
    #printf -- "[profile] popped: %s\n" $(date "+%S%N") >&2
    prune_array
    #printf -- "[profile] pruned: %s\n" $(date "+%S%N") >&2
    get_longest_filename
    #printf -- "[profile] long:   %s\n" $(date "+%S%N") >&2
    [[ $BUFFER_ALL_OUTPUT ]] && printf --"%s\n" "$(iterate_files)" || \
        iterate_files
    #printf -- "[profile] iter:   %s\n" $(date "+%S%N") >&2
    get_colour_glyph CLEAR
    summary
    #printf -- "[profile] summ:   %s\n" $(date "+%S%N") >&2
}


## execution start

main "$@"

