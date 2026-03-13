#!/bin/bash

# Check for required command-line utilities
command -v ffplay >/dev/null 2>&1 || { echo "ffplay is required but it's not installed. Aborting." >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg is required but it's not installed. Aborting." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required but it's not installed. Aborting." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required but it's not installed. Aborting." >&2; exit 1; }

# Audio URL to play
AUDIO_URL="https://wild-haze-hifi.deathsmack-a51.workers.dev"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORD_DIR="$SCRIPT_DIR/ZamRock Recordings"  # Directory to save recordings
API_URL="https://icy-voice-api.deathsmack-a51.workers.dev"  # AzuraCast API endpoint
WEBSITE_LINK="https://zamrock.net"

# Define colors
RED='\033[0;31m'    # Color for StreamTitle (when it changes)
GREEN='\033[0;32m'  # Color for StreamTitle (once displayed)
BLUE='\033[0;34m'   # Color for Genre
YELLOW='\033[1;33m' # Color for messages
CYAN='\033[0;36m'   # Color for help message
PURPLE='\033[0;35m' # Color for timer
NC='\033[0m'        # No Color

# Display settings
ASCII_DISPLAY_INTERVAL=600   # Show ASCII art every 10 minutes
TRACK_UPDATE_INTERVAL=2      # Update track info every 2 seconds
READ_TIMEOUT=0.2             # Polling interval for user input (seconds)
ascii_counter=0
LAST_ASCII_TIME=0
LAST_TRACK_REFRESH=0

# Global variables for timer and recording
TIMER_RUNNING=false
TIMER_PID=0
TIMER_DURATION=0
TIMER_START=0
RECORDING_PID=0
RECORDING_ACTIVE=false
INTERACTIVE_MODE=false
SHOULD_EXIT=false
CLEANED_UP=false
TYPEWRITER_MODE=true
TYPEWRITER_DELAY=0.03
FFMPEG_PID=0
VOLUME=80
DRAWING_IN_PROGRESS=false

strip_ansi() {
    printf '%s' "$1" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g'
}

clear_status_line() {
    printf "\r\033[K"
}

flush_input() {
    while read -n 1 -s -t 0 2>/dev/null; do :; done || true
}

type_print() {
    local text="$1"
    local newline="${2:-true}"
    local custom_delay="${3:-}"  # Optional custom delay
    local parsed
    printf -v parsed "%b" "$text"
    if $TYPEWRITER_MODE; then
        # Disable terminal echo to ignore key presses during printing
        stty -echo 2>/dev/null
        local i=0
        local len=${#parsed}
        local delay="${custom_delay:-$TYPEWRITER_DELAY}"
        while [ $i -lt $len ]; do
            local char="${parsed:i:1}"
            if [[ "$char" == $'\033' ]]; then
                local seq="$char"
                i=$((i+1))
                while [ $i -lt $len ]; do
                    local next="${parsed:i:1}"
                    seq+="$next"
                    i=$((i+1))
                    if [[ "$next" =~ [A-Za-z] ]]; then
                        break
                    fi
                done
                printf "%s" "$seq"
                continue
            fi
            printf "%s" "$char"
            sleep "$delay"
            i=$((i+1))
        done
        # Restore terminal echo
        stty echo 2>/dev/null
        if [ "$newline" = "true" ]; then
            printf "\n"
        fi
    else
        if [ "$newline" = "true" ]; then
            printf "%s\n" "$parsed"
        else
            printf "%s" "$parsed"
        fi
    fi
}

repeat_char() {
    local char="$1"
    local count="$2"
    local result=""
    local i
    for ((i=0; i<count; i++)); do
        result+="$char"
    done
    printf "%s" "$result"
}

render_box_line() {
    local text="$1"
    local max_len=$2
    local plain=$(strip_ansi "$text")
    local padding=$((max_len - ${#plain}))
    [ $padding -lt 0 ] && padding=0
    local spaces=$(repeat_char " " $padding)
    printf "%b\n" "${CYAN}║ ${NC}${text}${spaces}${CYAN} ║${NC}"
}

wrap_text() {
    local text="$1"
    local max_width=$2
    local plain=$(strip_ansi "$text")
    local len=${#plain}
    
    if [ $len -le $max_width ]; then
        echo "$text"
        return
    fi
    
    local result=""
    local remaining="$text"
    local word ansi_buffer=""
    local in_ansi=false
    
    while [ ${#remaining} -gt 0 ]; do
        local plain_remaining=$(strip_ansi "$remaining")
        local plain_len=${#plain_remaining}
        
        if [ $plain_len -le $max_width ]; then
            if [ -n "$result" ]; then
                result+=$'\n'
            fi
            result+="$remaining"
            break
        fi
        
        local line=""
        local line_plain=""
        remaining=""
        
        for ((i=0; i<${#remaining}; i++)); do
            local char="${remaining:i:1}"
            
            if [[ "$char" == $'\033' ]]; then
                ansi_buffer="$char"
                local seq="$char"
                local j=$((i+1))
                while [ $j -lt ${#remaining} ]; do
                    local next="${remaining:j:1}"
                    seq+="$next"
                    if [[ "$next" =~ [A-Za-z] ]]; then
                        break
                    fi
                    j=$((j+1))
                done
                ansi_buffer="$seq"
                line+="$seq"
                continue
            fi
            
            line+="$char"
            local test_line_plain=$(strip_ansi "$line")
            
            if [ ${#test_line_plain} -gt $max_width ]; then
                line="${line:0:-1}"
                remaining="${remaining:i}"
                break
            fi
        done
        
        if [ -n "$result" ]; then
            result+=$'\n'
        fi
        result+="$line"
    done
    
    printf '%s' "$result"
}

render_box() {
    local title="$1"
    shift
    local content=("$@")
    
    local term_cols=$(tput cols 2>/dev/null || echo 80)
    local max_allowed=$((term_cols - 4))
    [ $max_allowed -lt 40 ] && max_allowed=40
    [ $max_allowed -gt 76 ] && max_allowed=76
    
    local wrapped_lines=()
    
    for line in "${content[@]}"; do
        local plain=$(strip_ansi "$line")
        if [ ${#plain} -gt $max_allowed ]; then
            local words=()
            read -ra words <<< "$line"
            local current=""
            for word in "${words[@]}"; do
                local test_line="$current $word"
                if [ -z "$current" ]; then
                    test_line="$word"
                fi
                local test_plain=$(strip_ansi "$test_line")
                if [ ${#test_plain} -le $max_allowed ]; then
                    current="$test_line"
                else
                    if [ -n "$current" ]; then
                        wrapped_lines+=("$current")
                    fi
                    current="$word"
                fi
            done
            [ -n "$current" ] && wrapped_lines+=("$current")
        else
            wrapped_lines+=("$line")
        fi
    done
    
    local max_len=0
    local plain_line
    local all_lines=("$title" "${wrapped_lines[@]}")
    for line in "${all_lines[@]}"; do
        plain_line=$(strip_ansi "$line")
        local len=${#plain_line}
        if [ $len -gt $max_len ]; then
            max_len=$len
        fi
    done
    
    [ $max_len -gt $max_allowed ] && max_len=$max_allowed
    
    local inner_width=$max_len
    local border=$(repeat_char "═" $inner_width)
    printf "%b\n" "${CYAN}╔${border}╗${NC}"
    render_box_line "$title" "$max_len"
    printf "%b\n" "${CYAN}╠${border}╣${NC}"
    for line in "${wrapped_lines[@]}"; do
        render_box_line "$line" "$max_len"
    done
    printf "%b\n" "${CYAN}╚${border}╝${NC}"
}

toggle_typewriter_mode() {
    if $TYPEWRITER_MODE; then
TYPEWRITER_MODE=true
        type_print "${YELLOW}Typewriter mode disabled.${NC}"
    else
        TYPEWRITER_MODE=true
        type_print "${YELLOW}Typewriter mode enabled.${NC}"
    fi
}

parse_size_to_bytes() {
    local input="${1,,}"
    if [[ "$input" =~ ^([0-9]+)([kmg]?b?)$ ]]; then
        local value=${BASH_REMATCH[1]}
        local unit=${BASH_REMATCH[2]}
        case "$unit" in
            ""|"b") echo "$value" ;;
            "k"|"kb") echo $((value * 1024)) ;;
            "m"|"mb") echo $((value * 1024 * 1024)) ;;
            "g"|"gb") echo $((value * 1024 * 1024 * 1024)) ;;
            *)
                return 1
                ;;
        esac
    else
        return 1
    fi
}

# Function to print ASCII Art with color
print_ascii_art() {
    # Generate 8 different random colors for the logo
    local colors=()
    for i in {1..8}; do
        colors+=($((RANDOM % 6 + 31)))  # Random color between 31-36
    done
    
    # Print each line with a different color
    printf "\n"
    printf "\033[1;${colors[0]}m"
    cat << "EOF"
 __________             __________               __
 \____    /____    _____\______   \ ____   ____ |  | __
   /     /\__  \  /     \|       _//  _ \_/ ___\|  |/ /
  /     /_ / __ \|  Y Y  \    |   (  <_> )  \___|    <
 /_______ (____  /__|_|  /____|_  /\____/ \___  >__|_ \
        \/    \/      \/       \/            \/     \/
        __________             .___.__
        \______   \_____     __| _/|__| ____
         |       _/\__  \   / __ | |  |/  _ \
         |    |   \ / __ \_/ /_/ | |  (  <_> )
         |____|_  /(____  /\____ | |__|\____/
               \/      \/      \/
EOF
    printf "\033[1;${colors[7]}m"
    type_print "Visit us at: https://zamrock.net"
    printf "${NC}"  # Reset color
    type_print "ZamRock Radio - The Home of Zambian Rock Music"
}

print_now_playing_card() {
    local song_title="${1:-$LAST_STREAM_TITLE}"
    local artist="${2:-$LAST_ARTIST}"
    local album="${3:-$LAST_ALBUM}"
    local playlist="${4:-$LAST_PLAYLIST}"
    local duration="${5:-$LAST_DURATION}"

    if [ -z "$song_title" ]; then
        type_print "${CYAN}Loading track information...${NC}"
        return
    fi

    # Get terminal width dynamically like bashsimplecurses
    local term_width=$(tput cols 2>/dev/null || echo 80)
    [ $term_width -lt 40 ] && term_width=40
    [ $term_width -gt 100 ] && term_width=100
    local inner=$((term_width - 2))
    
    # Build border strings - works with any terminal
    local top_border="╔"
    local bot_border="╚"
    local mid_border="╠"
    local left_border="║"
    local right_border="║"
    local top_bottom="═"
    local mid_horiz="═"
    local mid_vert="╬"
    
    # Create the horizontal lines
    local horiz=""
    local i
    for ((i=0; i<inner; i++)); do
        horiz="${horiz}${top_bottom}"
    done

    echo ""
    echo -e "${CYAN}${top_border}${horiz}${right_border}${NC}"
    echo -e "${CYAN}${left_border}${NC}  ${YELLOW}ZamRock Radio - Now Playing${NC}"
    echo -e "${CYAN}${mid_border}${horiz}${mid_vert}${NC}"
    echo -e "${CYAN}${left_border}${NC}  Title:   ${song_title}"
    echo -e "${CYAN}${left_border}${NC}  Artist:  ${artist}"
    if [ "$album" != "Unknown Album" ]; then
        echo -e "${CYAN}${left_border}${NC}  Album:   ${album}"
    fi
    if [ "$playlist" != "Unknown Collection" ]; then
        echo -e "${CYAN}${left_border}${NC}  Playlist: ${playlist}"
    fi
    local dur_str
    if [[ "$duration" =~ ^[0-9]+$ ]] && [ "$duration" -gt 0 ]; then
        dur_str=$(format_duration $duration)
    else
        dur_str="Unknown"
    fi
    echo -e "${CYAN}${left_border}${NC}  Duration: ${dur_str}"
    echo -e "${CYAN}${bot_border}${horiz}${right_border}${NC}"
}

show_logo_and_now_playing() {
    print_ascii_art
    print_now_playing_card
    LAST_ASCII_TIME=$(date +%s)
}

enter_interactive_mode() {
    if ! $INTERACTIVE_MODE; then
        INTERACTIVE_MODE=true
        clear_status_line
        flush_input
    fi
}

exit_interactive_mode() {
    if $INTERACTIVE_MODE; then
        INTERACTIVE_MODE=false
        clear_status_line
        flush_input
    fi
}

prompt_wait_for_next_track() {
    echo -e "${YELLOW}Do you want to wait for the next track before recording?${NC}"
    read -n 1 -s -p "(y/n): " wait_choice
    echo
    if [[ "$wait_choice" =~ ^[Yy]$ ]]; then
        wait_for_next_track_start
        return $?
    fi
    echo -e "${YELLOW}Starting recording immediately.${NC}"
    return 0
}

wait_for_next_track_start() {
    local current_title="$LAST_STREAM_TITLE"
    local key=""
    if [ -z "$current_title" ]; then
        echo -e "${YELLOW}Track information unavailable, starting immediately.${NC}"
        return 0
    fi

    echo -e "${YELLOW}Waiting for the next track to begin... (press 'c' to cancel, 'q' to quit)${NC}"
    local wait_start=$(date +%s)

    while true; do
        for _ in {1..10}; do
            if read -t 0.1 -n 1 -s key; then
                case "$key" in
                    "c"|"a")
                        echo -e "${YELLOW}Cancelled waiting for next track.${NC}"
                        return 1
                        ;;
                    "q")
                        echo -e "${YELLOW}Quit requested. Stopping playback...${NC}"
                        SHOULD_EXIT=true
                        return 2
                        ;;
                esac
            fi
        done
        local metadata=$(fetch_metadata)
        if [ -n "$metadata" ]; then
            IFS='|' read -r song_title artist album playlist duration elapsed remaining <<< "$metadata"
            if [ "$song_title" != "$current_title" ] && [ "$song_title" != "Unknown Track" ]; then
                LAST_STREAM_TITLE="$song_title"
                LAST_ARTIST="$artist"
                LAST_ALBUM="$album"
                LAST_PLAYLIST="$playlist"
                LAST_DURATION=$duration
                echo -e "${GREEN}New track detected: ${song_title} by ${artist}${NC}"
                break
            fi
        fi

        if [ $(( $(date +%s) - wait_start )) -ge 600 ]; then
            echo -e "${YELLOW}No new track detected after 10 minutes. Recording will start now.${NC}"
            break
        fi
    done
    return 0
}

# Function to create a directory for recordings if it doesn't exist
create_recording_directory() {
    if [ ! -d "$RECORD_DIR" ]; then
        mkdir -p "$RECORD_DIR"
        echo -e "${YELLOW}Created directory for recordings: $RECORD_DIR${NC}"
    fi
}

# Function to fetch metadata from AzuraCast API
fetch_metadata() {
    local response
    local exit_code
    
    # Fetch metadata using curl with timeout
    response=$(curl -s -w "%{http_code}" --max-time 10 "$API_URL" 2>/dev/null)
    exit_code="${response: -3}"
    response="${response%???}"
    
    if [ "$exit_code" = "200" ] && [ -n "$response" ]; then
        # Parse JSON response using jq
        local song_title=$(echo "$response" | jq -r '.now_playing.song.title // .now_playing.song.text // "Unknown Track"')
        local artist=$(echo "$response" | jq -r '.now_playing.song.artist // "Unknown Artist"')
        local album=$(echo "$response" | jq -r '.now_playing.song.album // "Unknown Album"')
        local playlist=$(echo "$response" | jq -r '.now_playing.playlist // "Unknown Collection"')
        # API returns seconds directly
        local duration=$(echo "$response" | jq -r '.now_playing.duration // 0')
        local elapsed=$(echo "$response" | jq -r '.now_playing.elapsed // 0')
        local remaining=$(echo "$response" | jq -r '.now_playing.remaining // 0')
        
        echo "$song_title|$artist|$album|$playlist|$duration|$elapsed|$remaining"
    else
        echo ""
    fi
}

# Function to format duration in seconds to readable string
format_duration() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    
    if [ $hours -gt 0 ]; then
        printf "%02d:%02d:%02d" $hours $minutes $secs
    else
        printf "%02d:%02d" $minutes $secs
    fi
}

# Function to draw a progress bar
draw_progress_bar() {
    local current=$1
    local total=$2
    local bar_length=30
    local message="$3"
    local color="$4"
    
    # Use yellow if no color specified
    [ -z "$color" ] && color="YELLOW"
    
    # Get the color code
    local color_code="${!color}"
    
    if [ $total -eq 0 ]; then
        printf "\r${color_code}%s [%s] %s/%s${NC}" \
            "$message" \
            "$(printf '%*s' $bar_length | tr ' ' '?')" \
            "$(format_duration $current)" \
            "$(format_duration $total)"
        return
    fi
    
    # Ensure current doesn't exceed total
    if [ $current -gt $total ]; then
        current=$total
    fi
    
    local filled=$(( (bar_length * current) / total ))
    local empty=$(( bar_length - filled ))
    
    # Ensure filled doesn't exceed bar length
    if [ $filled -gt $bar_length ]; then
        filled=$bar_length
        empty=0
    fi
    
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    
    printf "\r${color_code}%s [%s] %s/%s${NC}" \
        "$message" \
        "$bar" \
        "$(format_duration $current)" \
        "$(format_duration $total)"
}

# Function to show now playing progress with real duration
show_now_playing_progress() {
    local duration=$1
    local elapsed=$2
    local remaining=$3
    
    if [ $duration -eq 0 ]; then
        echo -e "${CYAN}Now Playing - Duration unknown${NC}"
        return
    fi
    
    # Show progress for the remaining time of the current track
    for ((i=0; i<=remaining; i++)); do
        local current_elapsed=$((elapsed + i))
        draw_progress_bar $current_elapsed $duration "Now Playing"
        sleep 1
        
        # Check if we've reached the end of the track
        if [ $current_elapsed -ge $duration ]; then
            break
        fi
    done
    echo ""  # New line after progress bar
}

# Function to prompt user to select recording duration
select_record_duration() {
    echo -e "${CYAN}Select a recording duration:${NC}"
    echo -e "${YELLOW}a) 10 seconds (10 seconds) for testing${NC}"
    echo -e "${YELLOW}b) 5 minutes (300 seconds) for longer tests${NC}"
    echo -e "${YELLOW}c) 30 minutes (1800 seconds)${NC}"
    echo -e "${YELLOW}d) 1 hour (3600 seconds)${NC}"
    echo -e "${YELLOW}e) 2 hours (7200 seconds)${NC}"
    echo -e "${YELLOW}f) 4 hours (14400 seconds)${NC}"

    read -n 1 -s -p "Please choose (a/b/c/d/e/f): " choice
    echo  # Move to the next line after user's input

    case $choice in
        a) duration=10 ;;     # 10 seconds
        b) duration=300 ;;    # 5 minutes
        c) duration=1800 ;;   # 30 minutes
        d) duration=3600 ;;   # 1 hour
        e) duration=7200 ;;  # 2 hours
        f) duration=14400 ;;  # 4 hours
        *) echo -e "${RED}Invalid choice. Recording for 10 seconds by default.${NC}"; duration=10 ;;
    esac

    # Start the recording
    record_audio "$duration"
}

# Function to record specified seconds of audio with progress bar
record_audio() {
    local duration=$1
    local date=$(date +"%Y-%m-%d")
    local timestamp=$(date +"%H-%M-%S")
    local file_path="$RECORD_DIR/ZamRock_${duration}s_${date}_${timestamp}.mp3"

    echo -e "${YELLOW}Archiving audio for ${duration} seconds...${NC}"

    # Run ffmpeg in the background
    ffmpeg -t "${duration}" -i "$AUDIO_URL" -acodec copy "$file_path" -y -loglevel quiet &
    FFMPEG_PID=$!

    # Progress bar while recording
    for ((i=0; i<=duration; i++)); do
        draw_progress_bar $i $duration "Recording"
        sleep 1
        
        # Check if ffmpeg is still running
        if ! kill -0 $FFMPEG_PID 2>/dev/null; then
            break
        fi
    done
    echo ""  # New line after progress bar

    # Wait for ffmpeg to finish
    wait $FFMPEG_PID
    echo -e "${YELLOW}Recording saved to: $file_path${NC}"

    echo -e "${YELLOW}Recording complete. File stored locally.${NC}"
}

# Function to start a timer for Ramen Noodle Timer
start_noodle_timer() {
    if $TIMER_RUNNING; then
        # Cancel existing timer
        if [ -f "/tmp/timer_cancel_$TIMER_PID" ]; then
            rm -f "/tmp/timer_cancel_$TIMER_PID"
        fi
        touch "/tmp/timer_cancel_$TIMER_PID"
        TIMER_RUNNING=false
        # Make sure the timer process is really dead
        kill -9 $TIMER_PID 2>/dev/null
        wait $TIMER_PID 2>/dev/null
        echo -e "\n${YELLOW}⏹️  Timer cancelled${NC}"
        return
    fi
    
    local duration=180  # 3 minutes
    TIMER_START=$(date +%s)
    TIMER_DURATION=$duration
    TIMER_RUNNING=true
    
    (
        for ((i=0; i<=duration; i++)); do
            if [ -f "/tmp/timer_cancel_$TIMER_PID" ]; then
                rm -f "/tmp/timer_cancel_$TIMER_PID"
                break
            fi
            sleep 1
        done
        
        if [ $i -ge $duration ]; then
            # Timer completed
            echo -e "\n${GREEN}⏰ Timer completed! Ready to eat noodles! 🍜${NC}"
            # Play a sound if available
            if command -v paplay &> /dev/null; then
                paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || \
                paplay /usr/share/sounds/gnome/default/alerts/glass.ogg 2>/dev/null || \
                echo -e "\a"  # Fallback to terminal bell
            else
                echo -e "\a"  # Terminal bell
            fi
        fi
        
        TIMER_RUNNING=false
    ) &
    TIMER_PID=$!
    disown
    
    echo -e "\n${GREEN}⏱️  Ramen Timer started for $(format_duration $duration)${NC}"
    echo -e "${YELLOW}Press 'r' again to cancel the timer${NC}"
}

# Function to record the stream
record_stream() {
    clear_status_line
    echo -e "\n${CYAN}🎙️  Recording Options:${NC}"
    echo "1. 10 second test clip"
    echo "2. Custom duration (e.g., 30s, 2m, 1h)"
    echo "3. Record until specific file size (e.g., 5mb, 1gb)"
    echo -n "Select an option (1-3): "
    read -r choice
    
    local action=""
    local duration_value=""
    local duration_label=""
    local size_value=""
    
    case $choice in
        1)
            action="duration"
            duration_value=10
            duration_label="10s_test"
            ;;
        2)
            echo -n "Enter duration (e.g., 30s, 2m, 1h): "
            read -r duration_value
            if [ -z "$duration_value" ]; then
                echo -e "${YELLOW}No duration entered. Returning to menu.${NC}"
                return
            fi
            action="duration"
            duration_label="custom_${duration_value}"
            ;;
        3)
            echo -n "Enter file size (e.g., 5mb, 1gb): "
            read -r size_value
            if [ -z "$size_value" ]; then
                echo -e "${YELLOW}No file size entered. Returning to menu.${NC}"
                return
            fi
            action="size"
            ;;
        *)
            echo -e "${YELLOW}Invalid option. Returning to main menu.${NC}"
            return
            ;;
    esac
    
    prompt_wait_for_next_track
    local wait_status=$?
    case $wait_status in
        0)
            ;;
        1)
            echo -e "${YELLOW}Recording cancelled before it started.${NC}"
            return
            ;;
        2)
            SHOULD_EXIT=true
            return
            ;;
    esac
    
    if [ "$action" = "duration" ]; then
        record_duration "$duration_value" "$duration_label"
    else
        record_until_size "$size_value"
    fi
}

# Record for a specific duration
record_duration() {
    local duration=$1
    local prefix=$2
    local filename="${prefix}_$(date +%Y%m%d_%H%M%S).mp3"
    local filepath="$RECORD_DIR/$filename"
    
    mkdir -p "$RECORD_DIR"
    
    # Clear any existing trap
    trap - INT
    
    echo -e "\n${YELLOW}🎙️  Recording $duration of audio to:${NC}"
    echo -e "${CYAN}$filepath${NC}"
    echo -e "${YELLOW}Press 'a' to cancel recording${NC}"
    
    # Start recording in background
    ffmpeg -y -t $duration -i "$AUDIO_URL" -c copy "$filepath" >/dev/null 2>&1 &
    RECORDING_PID=$!
    RECORDING_ACTIVE=true
    
    # Monitor for cancel key or completion
    while kill -0 $RECORDING_PID 2>/dev/null; do
        # Check for cancel key (non-blocking read)
        if read -t 0.1 -n 1 -s key && [[ "$key" == "a" ]]; then
            kill $RECORDING_PID 2>/dev/null
            echo -e "\n${YELLOW}Recording cancelled by user.${NC}"
            RECORDING_ACTIVE=false
            break
        fi
        
        # Show recording status
        if [ -f "$filepath" ]; then
            local current_size=$(du -h "$filepath" | cut -f1)
            local duration_sec=$(( $(date +%s) - $(date -r "$filepath" +%s) ))
            printf "\rRecording: %-10s  Duration: %02d:%02d" "$current_size" $((duration_sec/60)) $((duration_sec%60))
        fi
        sleep 0.5
    done
    
    # Clean up
    wait $RECORDING_PID 2>/dev/null
    RECORDING_ACTIVE=false
    
    # Show final status
    if [ -f "$filepath" ] && [ -s "$filepath" ]; then
        local final_size=$(du -h "$filepath" | cut -f1)
        echo -e "\n${GREEN}✅ Recording complete!${NC}"
        echo -e "   File: ${CYAN}$filepath${NC}"
        echo -e "   Size: ${GREEN}$final_size${NC}"
    else
        # Clean up empty file if any
        [ -f "$filepath" ] && rm -f "$filepath"
        echo -e "\n${YELLOW}⚠️  Recording was cancelled or failed${NC}"
    fi
    
    # Reset trap
    trap - INT
}

# Record until specific file size is reached
record_until_size() {
    local target_size=$1
    local bytes
    bytes=$(parse_size_to_bytes "$target_size") || {
        echo -e "${RED}Invalid size format. Use values like 5mb, 500kb, 1gb.${NC}"
        return
    }
    local filename="size_${target_size}_$(date +%Y%m%d_%H%M%S).mp3"
    local filepath="$RECORD_DIR/$filename"
    
    mkdir -p "$RECORD_DIR"
    
    echo -e "\n${YELLOW}🎙️  Recording until file reaches $target_size ...${NC}"
    
    ffmpeg -y -i "$AUDIO_URL" -c copy -fs $bytes "$filepath" >/dev/null 2>&1 &
    RECORDING_PID=$!
    RECORDING_ACTIVE=true
    
    echo -e "${CYAN}Recording in progress... Press Ctrl+C to stop early${NC}"
    
    trap 'kill $RECORDING_PID 2>/dev/null; RECORDING_ACTIVE=false; echo -e "\n${YELLOW}Recording stopped.${NC}"; return' INT
    
    while kill -0 $RECORDING_PID 2>/dev/null; do
        if read -t 0.1 -n 1 -s key && [[ "$key" == "a" ]]; then
            kill $RECORDING_PID 2>/dev/null
            echo -e "\n${YELLOW}Recording cancelled by user.${NC}"
            RECORDING_ACTIVE=false
            break
        fi
        if [ -f "$filepath" ]; then
            local current_size=$(du -h "$filepath" | cut -f1)
            printf "\rCurrent size: %-8s" "$current_size"
        fi
        sleep 1
    done
    
    if [ -f "$filepath" ]; then
        echo -e "\n${GREEN}✅ Recording complete. Final size: $(du -h "$filepath" | cut -f1)${NC}"
        echo -e "File saved to: $filepath"
    else
        echo -e "\n${RED}❌ Failed to record audio${NC}"
    fi
    RECORDING_ACTIVE=false
    trap - INT
}

# Settings file handling
SETTINGS_FILE="$SCRIPT_DIR/zamrock_settings.conf"

load_settings() {
    if [ -f "$SETTINGS_FILE" ]; then
        source "$SETTINGS_FILE"
    else
        VOLUME=80
        SAVE_SETTINGS=true
        TYPEWRITER_MODE=true
    fi
}

save_settings() {
    if [ "$SAVE_SETTINGS" = true ]; then
        cat > "$SETTINGS_FILE" << EOF
VOLUME=$VOLUME
SAVE_SETTINGS=$SAVE_SETTINGS
TYPEWRITER_MODE=$TYPEWRITER_MODE
EOF
    fi
}

# Startup Menu
show_startup_menu() {
    DRAWING_IN_PROGRESS=true
    # Hide cursor
    tput civis
    
    # Restore cursor on exit
    trap 'tput cnorm; exit 0' INT TERM
    
    local menu_items=("Play" "Volume" "Settings" "Help" "Exit")
    local selected=0
    local num_items=${#menu_items[@]}
    local menu_drawn=false
    
    # Clear any keys pressed before showing menu
    flush_input
    
    load_settings
    
    while true; do
        rows=$(tput lines 2>/dev/null || echo 24)
        cols=$(tput cols 2>/dev/null || echo 80)
        
        # Only redraw menu when needed
        if [ "$menu_drawn" = false ]; then
            clear
            
            # Get terminal size for centering
            rows=$(tput lines 2>/dev/null || echo 24)
            cols=$(tput cols 2>/dev/null || echo 80)
            
            # Logo is 53 chars wide, center it
            logo_col=$(( (cols - 53) / 2 ))
            [ $logo_col -lt 1 ] && logo_col=1
            logo_row=1
            
            # Calculate positions
            tagline_col=$(( (cols - 17) / 2 ))
            [ $tagline_col -lt 1 ] && tagline_col=1
            tagline_row=16
            
            menu_start=20
            menu_col=$(( (cols - 8) / 2 ))
            [ $menu_col -lt 1 ] && menu_col=1
            
            website_col=$(( (cols - 19) / 2 ))
            [ $website_col -lt 1 ] && website_col=1
            website_row=29
            
            # 1. Print tagline (slow - 0.08)
            tput cup $tagline_row $tagline_col
            type_print "ZamZam for life..." "" 0.08
            
            # 2. Print logo (fast - 0.002)
            tput cup $logo_row $logo_col
            type_print "__________             __________               __" "" 0.002
            tput cup $((logo_row + 1)) $logo_col
            type_print '\\____    /____    _____\\______   \\ ____   ____ |  | __' "" 0.002
            tput cup $((logo_row + 2)) $logo_col
            type_print '  /     /\\__  \\  /     \\|       _//  _ \\_/ __\\|  |/ /' "" 0.002
            tput cup $((logo_row + 3)) $logo_col
            type_print ' /     /_ / __ \\|  Y Y  \\    |   (  <_> )  \\___|    <' "" 0.002
            tput cup $((logo_row + 4)) $logo_col
            type_print '/_______ (____  /__|_|  /____|_  /\\____/ \\___  >__|_ \\' "" 0.002
            tput cup $((logo_row + 5)) $logo_col
            type_print '        \\/    \\/      \\/       \\/            \\/     \\/' "" 0.002
            
            tput cup $((logo_row + 7)) $logo_col
            type_print '       __________             .___.__' "" 0.002
            tput cup $((logo_row + 8)) $logo_col
            type_print '       \\______   \\_____     __| _/|__| ____' "" 0.002
            tput cup $((logo_row + 9)) $logo_col
            type_print '        |       _/\\__  \\   / __ | |  |/  _ \\' "" 0.002
            tput cup $((logo_row + 10)) $logo_col
            type_print '        |    |   \\ / __ \\_/ /_/ | |  (  <_> )' "" 0.002
            tput cup $((logo_row + 11)) $logo_col
            type_print '        |____|_  /(____  /\\____ | |__|\\____\\/' "" 0.002
            tput cup $((logo_row + 12)) $logo_col
            type_print '               \\/      \\/' "" 0.002
            
            # 3. Print website (normal speed)
            tput cup $website_row $website_col
            type_print "https://zamrock.net"
            
            # 4. Print menu (normal speed)
            for i in "${!menu_items[@]}"; do
                tput cup $((menu_start + i)) $menu_col
                if [ $i -eq $selected ]; then
                    type_print "${GREEN}> ${menu_items[i]}${NC}"
                else
                    printf "  ${menu_items[i]}"
                fi
            done
            
            menu_drawn=true
            DRAWING_IN_PROGRESS=false
        fi
        
        read -rsn1 key
        
        # Handle arrow keys (escape sequences: \e[A, \e[B)
        if [ "$key" = $'\e' ]; then
            read -rsn1 -t 0.1 key
            if [ "$key" = "[" ]; then
                read -rsn1 -t 0.1 key
            fi
        fi
        
        case "$key" in
            "")
                clear
                case $selected in
                    0) menu_drawn=false; return 0 ;;
                    1) show_volume_menu; menu_drawn=false ;;
                    2) show_settings_menu; menu_drawn=false ;;
                    3) show_startup_help; menu_drawn=false ;;
                    4) 
                        tput cnorm
                        echo -e "${YELLOW}Thank you for listening!${NC}"
                        exit 0
                        ;;
                esac
                ;;
            "A"|"a") 
                if [ $selected -gt 0 ]; then
                    selected=$((selected - 1))
                    # Update just the selection lines
                    tput cup $((menu_start + selected + 1)) $menu_col
                    printf "  ${menu_items[$selected]}"
                    tput cup $((menu_start + selected)) $menu_col
                    printf "${GREEN}> ${menu_items[$selected]}${NC}"
                fi
                ;;
            "B"|"b") 
                if [ $selected -lt $((num_items - 1)) ]; then
                    selected=$((selected + 1))
                    # Update just the selection lines
                    tput cup $((menu_start + selected - 1)) $menu_col
                    printf "  ${menu_items[$selected - 1]}"
                    tput cup $((menu_start + selected)) $menu_col
                    printf "${GREEN}> ${menu_items[$selected]}${NC}"
                fi
                ;;
            $'\e')  # Escape key - same as back
                tput cnorm
                echo -e "${YELLOW}Thank you for listening!${NC}"
                exit 0
                ;;
            "q"|"Q") 
                tput cnorm
                echo -e "${YELLOW}Thank you for listening!${NC}"
                exit 0
                ;;
        esac
    done
}

show_volume_menu() {
    while true; do
        rows=$(tput lines 2>/dev/null || echo 24)
        cols=$(tput cols 2>/dev/null || echo 80)
        
        clear
        tput cup $((rows / 2 - 4)) $((cols / 2 - 10))
        echo -e "${YELLOW}Volume Control${NC}"
        
        tput cup $((rows / 2)) $((cols / 2 - 8))
        echo "Current: ${VOLUME}%"
        
        local bar_len=20
        local filled=$((VOLUME * bar_len / 100))
        local empty=$((bar_len - filled))
        tput cup $((rows / 2 + 2)) $((cols / 2 - bar_len / 2))
        printf "${GREEN}["
        printf "%${filled}s" "" | tr ' ' '█'
        printf "${YELLOW}"
        printf "%${empty}s" "" | tr ' ' '░'
        printf "]${NC}"
        
        tput cup $((rows / 2 + 4)) $((cols / 2 - 14))
        echo "+/- or 0-9: Adjust"
        tput cup $((rows / 2 + 5)) $((cols / 2 - 10))
        echo "s: Save | b: Back"
        
        flush_input
        read -rsn1 key
        # Handle arrow keys (consume escape sequences)
        if [ "$key" = $'\e' ]; then
            read -rsn1 -t 0.1 key
            if [ "$key" = "[" ]; then
                read -rsn1 -t 0.1 key
            fi
        fi
        
        case "$key" in
            "A") [ $VOLUME -lt 100 ] && VOLUME=$((VOLUME + 5)) ;;
            "B") [ $VOLUME -gt 0 ] && VOLUME=$((VOLUME - 5)) ;;
            "+") [ $VOLUME -lt 100 ] && VOLUME=$((VOLUME + 5)) ;;
            "-") [ $VOLUME -gt 0 ] && VOLUME=$((VOLUME - 5)) ;;
            [0-9]) VOLUME=$((key * 10)) ;;
            "s"|"S") 
                save_settings
                tput cup $((rows / 2 + 6)) $((cols / 2 - 10))
                echo -e "${GREEN}Settings saved!${NC}"
                sleep 1
                ;;
            ""|"b"|"B"|$'\e') return ;;
        esac
    done
}

show_settings_menu() {
    while true; do
        rows=$(tput lines 2>/dev/null || echo 24)
        cols=$(tput cols 2>/dev/null || echo 80)
        
        clear
        tput cup $((rows / 2 - 6)) $((cols / 2 - 10))
        echo -e "${YELLOW}Settings${NC}"
        
        tput cup $((rows / 2 - 3)) $((cols / 2 - 15))
        [ "$SAVE_SETTINGS" = true ] && echo -e "Auto-save: ${GREEN}Enabled${NC}" || echo -e "Auto-save: ${RED}Disabled${NC}"
        
        tput cup $((rows / 2 - 1)) $((cols / 2 - 12))
        echo "Volume: ${VOLUME}%"
        
        local tw_label
        if $TYPEWRITER_MODE; then
            tw_label="ON"
        else
            tw_label="OFF"
        fi
        tput cup $((rows / 2 + 1)) $((cols / 2 - 15))
        if $TYPEWRITER_MODE; then
            echo -e "Typewriter: ${GREEN}${tw_label}${NC}"
        else
            echo -e "Typewriter: ${RED}${tw_label}${NC}"
        fi
        
        tput cup $((rows / 2 + 3)) $((cols / 2 - 16))
        echo "t: Toggle Auto-save"
        tput cup $((rows / 2 + 4)) $((cols / 2 - 12))
        echo "v: Set Volume"
        tput cup $((rows / 2 + 5)) $((cols / 2 - 14))
        echo "w: Toggle Typewriter"
        tput cup $((rows / 2 + 6)) $((cols / 2 - 10))
        echo "b: Back to Menu"
        
        flush_input
        read -rsn1 key
        # Handle arrow keys (consume escape sequence)
        if [ "$key" = $'\e' ]; then
            read -rsn1 -t 0.1 key
            if [ "$key" = "[" ]; then
                read -rsn1 -t 0.1 key
            fi
        fi
        
        case "$key" in
            "t"|"T") 
                if [ "$SAVE_SETTINGS" = true ]; then
                    SAVE_SETTINGS=false
                else
                    SAVE_SETTINGS=true
                    save_settings
                fi
                ;;
            "v"|"V") show_volume_menu ;;
            "w"|"W") 
                if $TYPEWRITER_MODE; then
                    TYPEWRITER_MODE=false
                else
                    TYPEWRITER_MODE=true
                fi
                save_settings
                ;;
            ""|"b"|"B"|$'\e') return ;;
        esac
    done
}

show_startup_help() {
    rows=$(tput lines 2>/dev/null || echo 24)
    cols=$(tput cols 2>/dev/null || echo 80)
    
    clear
    local inner=$((cols - 4))
    local horiz=""
    local i
    for ((i=0; i<inner; i++)); do
        horiz="${horiz}─"
    done
    
    tput cup 2 $((cols / 2 - 12))
    echo -e "${YELLOW}ZamRock CLI Help${NC}"
    
    tput cup 4 2
    echo -e "${CYAN}╔${horiz}╗${NC}"
    echo -e "${CYAN}║${NC}  ↑/↓   - Navigate"
    echo -e "${CYAN}║${NC}  Enter  - Select"
    echo -e "${CYAN}║${NC}  b/Esc - Back"
    echo -e "${CYAN}╠${horiz}╣${NC}"
    echo -e "${CYAN}║${NC}  Play    - Start radio"
    echo -e "${CYAN}║${NC}  Volume  - Adjust"
    echo -e "${CYAN}║${NC}  Settings - Configure"
    echo -e "${CYAN}║${NC}  Help    - This help"
    echo -e "${CYAN}╚${horiz}╝${NC}"
    
    tput cup $((rows - 3)) $((cols / 2 - 15))
    echo "Press any key to continue..."
    
    flush_input
    read -rsn1
}

# Show startup menu and get choice
show_startup_menu
menu_choice=$?

# menu_choice: 0=Play, 1=Volume, 2=Settings, 3=Help, 4=Exit
if [ $menu_choice -ne 0 ]; then
    tput cnorm
    # If not Play, exit (Exit was handled in menu)
    exit 0
fi

# User selected Play - restore cursor and continue to audio
tput cnorm

# Start playing audio in the background
echo "Playing audio stream..."

# Print ASCII Art just before starting the audio
print_ascii_art
LAST_ASCII_TIME=$(date +%s)

# Set default volume if not set
[ -z "$VOLUME" ] && VOLUME=80

# Start playback with ffplay
TMP_LOG=$(mktemp)
ffplay -nodisp -autoexit "$AUDIO_URL" -loglevel info -volume $VOLUME 2> "$TMP_LOG" &
PID=$!

# Print instructions
echo -e "${YELLOW}Press 'h' for help commands.${NC}"

# Initialize variables
LAST_STREAM_TITLE=""
LAST_ARTIST=""
LAST_ALBUM=""
LAST_PLAYLIST=""
LAST_DURATION=0
PAUSED=false
TIMER_CANCELLED=0
TIMER_RUNNING=false

# Create the recording directory
create_recording_directory

# Function to fetch lyrics (using a simple API)
get_lyrics() {
    local artist="$1"
    local title="$2"
    
    # Clean up the artist and title for URL
    artist=$(echo "$artist" | tr ' ' '+' | tr -d '[:punct:]')
    title=$(echo "$title" | tr ' ' '+' | tr -d '[:punct:]')
    
    echo -e "\n${CYAN}Searching for lyrics...${NC}"
    
    # Try to get lyrics (using a public API)
    local lyrics=$(curl -s --get --data-urlencode "artist=$artist" --data-urlencode "title=$title" \
        "https://api.lyrics.ovh/v1/$artist/$title" | jq -r '.lyrics' 2>/dev/null)
    
    if [ "$lyrics" != "null" ] && [ -n "$lyrics" ]; then
        echo -e "\n${GREEN}Lyrics for $LAST_STREAM_TITLE by $LAST_ARTIST:${NC}\n"
        echo "$lyrics"
    else
        echo -e "${YELLOW}No lyrics found for this track.${NC}"
    fi
}

# Function to display current track information with progress
display_track_info() {
    if $INTERACTIVE_MODE; then
        return
    fi

    local metadata=$(fetch_metadata)
    
    if [ -n "$metadata" ]; then
        IFS='|' read -r song_title artist album playlist duration elapsed remaining <<< "$metadata"
        
        # Check if track has changed
        if [ "$song_title" != "$LAST_STREAM_TITLE" ] || [ "$artist" != "$LAST_ARTIST" ]; then
            echo ""  # New line when track changes
            print_now_playing_card "$song_title" "$artist" "$album" "$playlist" "$duration"
            
            LAST_STREAM_TITLE="$song_title"
            LAST_ARTIST="$artist"
            LAST_ALBUM="$album"
            LAST_PLAYLIST="$playlist"
            LAST_DURATION=$duration
            
            # Show progress bar once when track changes
            if [[ "$duration" =~ ^[0-9]+$ ]] && [ "$duration" -gt 30 ]; then
                # Only show progress for tracks longer than 30 seconds
                draw_progress_bar $elapsed $duration "Now Playing" "GREEN"
            fi
        fi
    fi
}

# Initial display
echo -e "${CYAN}Loading track information...${NC}"
# Command help function
show_help() {
    DRAWING_IN_PROGRESS=true
    local remaining=0
    if $TIMER_RUNNING; then
        remaining=$((TIMER_START + TIMER_DURATION - $(date +%s)))
    fi
    local timer_status
    if [ $remaining -gt 0 ]; then
        timer_status="Running - $(format_duration $remaining) left"
    else
        timer_status="Not running"
    fi
    local typewriter_label
    if $TYPEWRITER_MODE; then
        typewriter_label="ON"
    else
        typewriter_label="OFF"
    fi

    local term_width=$(tput cols 2>/dev/null || echo 80)
    [ $term_width -lt 40 ] && term_width=40
    [ $term_width -gt 100 ] && term_width=100
    local inner=$((term_width - 2))
    
    local horiz=""
    local i
    for ((i=0; i<inner; i++)); do
        horiz="${horiz}─"
    done

    # Clear any keys pressed during playback
    flush_input
    
    # Print help menu with typewriter (horizontal lines fast)
    type_print "" 
    type_print "${CYAN}╔${horiz}╗${NC}" "" 0.002
    type_print "${CYAN}║${NC}  ${YELLOW}ZamRock CLI - Help Menu${NC}"
    type_print "${CYAN}╠${horiz}╣${NC}" "" 0.002
    type_print "${CYAN}║${NC}  p  Pause/unpause stream"
    type_print "${CYAN}║${NC}  r  Ramen Noodle Timer"
    type_print "${CYAN}║${NC}  a  Archive stream"
    type_print "${CYAN}║${NC}  i  ZamRock info & links"
    type_print "${CYAN}║${NC}  l  Search lyrics"
    type_print "${CYAN}║${NC}  n  Show logo & now playing"
    type_print "${CYAN}║${NC}  b  Return to player"
    type_print "${CYAN}║${NC}  t  Toggle typewriter ($typewriter_label)"
    type_print "${CYAN}║${NC}  h  This help menu"
    type_print "${CYAN}║${NC}  q  Quit"
    type_print "${CYAN}╠${horiz}╣${NC}" "" 0.002
    type_print "${CYAN}║${NC}  Now Playing: ${LAST_STREAM_TITLE:-Unknown Track}"
    type_print "${CYAN}║${NC}  Artist:     ${LAST_ARTIST:-Unknown Artist}"
    type_print "${CYAN}║${NC}  Timer:      $timer_status"
    type_print "${CYAN}╚${horiz}╝${NC}" "" 0.002
    
    echo
    echo -e "${YELLOW}Press b to return to player, or any key for command...${NC}"
    DRAWING_IN_PROGRESS=false
}

# Function to display information about ZamRock
show_info() {
    DRAWING_IN_PROGRESS=true
    flush_input
    
    local term_width=$(tput cols 2>/dev/null || echo 80)
    [ $term_width -lt 40 ] && term_width=40
    [ $term_width -gt 100 ] && term_width=100
    local inner=$((term_width - 2))
    
    local horiz=""
    local i
    for ((i=0; i<inner; i++)); do
        horiz="${horiz}─"
    done

    echo ""
    echo -e "${CYAN}╔${horiz}╗${NC}"
    echo -e "${CYAN}║${NC}  ${YELLOW}ZamRock Radio - Connect With Us${NC}"
    echo -e "${CYAN}╠${horiz}╣${NC}"
    echo -e "${CYAN}║${NC}  Website:   https://zamrock.net"
    echo -e "${CYAN}║${NC}  Matrix:    https://matrix.to/#/#zamrock:unredacted.org"
    echo -e "${CYAN}║${NC}  Mastodon:  https://musicworld.social/@ZamRock"
    echo -e "${CYAN}║${NC}  BlueSky:   https://bsky.app/profile/zamrock.net"
    echo -e "${CYAN}║${NC}  Discord:   https://discord.gg/TGNSc9kTjR"
    echo -e "${CYAN}║${NC}  Revolt:    https://stt.gg/CsjKzYWm"
    echo -e "${CYAN}╠${horiz}╣${NC}"
    echo -e "${CYAN}║${NC}  Now Playing: ${LAST_STREAM_TITLE:-Unknown Track}"
    echo -e "${CYAN}║${NC}  Artist:     ${LAST_ARTIST:-Unknown Artist}"
    echo -e "${CYAN}║${NC}  Album:      ${LAST_ALBUM:-Unknown Album}"
    echo -e "${CYAN}╚${horiz}╝${NC}"
    
    echo
    echo -e "${YELLOW}Press b to return to player, or any key for command...${NC}"
    DRAWING_IN_PROGRESS=false
}

cleanup() {
    if $CLEANED_UP; then
        return
    fi
    CLEANED_UP=true
    
    kill $PID 2>/dev/null
    [ -n "$TIMER_PID" ] && kill $TIMER_PID 2>/dev/null
    [ -n "$RECORDING_PID" ] && kill $RECORDING_PID 2>/dev/null
    [ -n "$FFMPEG_PID" ] && kill $FFMPEG_PID 2>/dev/null
    rm -f "$TMP_LOG"
    tput cnorm
    echo -e "${YELLOW}Playback finished.${NC}"
}

trap cleanup EXIT SIGINT SIGTERM

# Function to update timer display
update_timer_display() {
    if $TIMER_RUNNING; then
        local elapsed=$(( $(date +%s) - TIMER_START ))
        local remaining=$(( TIMER_DURATION - elapsed ))
        
        if [ $remaining -le 0 ]; then
            TIMER_RUNNING=false
            echo -e "\n${GREEN}⏰ Ramen is ready! Enjoy! 🍜${NC}"
            # Show song info after timer completes
            display_track_info
            return
        fi
        
        printf "\r\033[K"  # Clear current line
        draw_progress_bar $elapsed $TIMER_DURATION "🍜 Ramen Timer" "PURPLE"
        return 1  # Indicate timer is running
    fi
    return 0  # Indicate timer is not running
}

# Start the input loop for user commands
while kill -0 $PID 2>/dev/null; do
    if $SHOULD_EXIT; then
        break
    fi
    current_time=$(date +%s)

    if ! $INTERACTIVE_MODE; then
        if [ $((current_time - LAST_TRACK_REFRESH)) -ge $TRACK_UPDATE_INTERVAL ]; then
            display_track_info
            LAST_TRACK_REFRESH=$current_time
        fi

        if [ $((current_time - LAST_ASCII_TIME)) -ge $ASCII_DISPLAY_INTERVAL ]; then
            show_logo_and_now_playing
        fi
    fi
    
    # Update timer display only when not recording or in menus
    if $TIMER_RUNNING && ! $RECORDING_ACTIVE && ! $INTERACTIVE_MODE; then
        update_timer_display
    fi
    
    # Skip input while drawing menus to avoid key conflicts
    if $DRAWING_IN_PROGRESS; then
        sleep 0.1
        continue
    fi
    
    # Use shorter timeout for more responsive input
    read -n 1 -s -t 0.3 key
    if [ -z "$key" ]; then
        continue
    fi
    
    # Handle arrow keys (escape sequences: \e[A=up, \e[B=down, \e[C=right, \e[D=left)
    if [ "$key" = $'\e' ]; then
        read -rsn1 -t 0.1 key
        if [ "$key" = "[" ]; then
            read -rsn1 -t 0.1 key
            # Arrow keys ignored - use Settings menu to change volume
            continue
        else
            continue
        fi
    fi

    LAST_CMD="$key"

    case "$key" in
        "p")
            show_logo_and_now_playing
            if $PAUSED; then
                echo -e "\n${GREEN}▶️  Resuming playback...${NC}"
                kill -CONT $PID
                PAUSED=false
            else
                echo -e "\n${YELLOW}⏸️  Pausing playback...${NC}"
                kill -STOP $PID
                PAUSED=true
            fi
            ;;
        "r")
            show_logo_and_now_playing
            if $TIMER_RUNNING; then
                touch "/tmp/timer_cancel_$TIMER_PID"
                TIMER_RUNNING=false
                echo -e "\n${YELLOW}⏹️  Timer cancelled${NC}"
            else
                start_noodle_timer
            fi
            ;;
        "a")
            show_logo_and_now_playing
            if $RECORDING_ACTIVE; then
                echo -e "\n${YELLOW}Stopping recording...${NC}"
                kill $RECORDING_PID 2>/dev/null
                RECORDING_ACTIVE=false
            else
                enter_interactive_mode
                record_stream
                exit_interactive_mode
            fi
            ;;
        "i")
            show_logo_and_now_playing
            enter_interactive_mode
            show_info
            exit_interactive_mode
            flush_input
            ;;
        "h")
            enter_interactive_mode
            show_help
            exit_interactive_mode
            flush_input
            ;;
        "l")
            show_logo_and_now_playing
            enter_interactive_mode
            if [ -n "$LAST_STREAM_TITLE" ] && [ -n "$LAST_ARTIST" ]; then
                get_lyrics "$LAST_ARTIST" "$LAST_STREAM_TITLE"
                echo -e "\n${YELLOW}Press any key to continue...${NC}"
                read -n 1 -s
            else
                echo -e "\n${YELLOW}No track information available to search for lyrics.${NC}"
                sleep 2
            fi
            exit_interactive_mode
            ;;
        "t")
            enter_interactive_mode
            toggle_typewriter_mode
            exit_interactive_mode
            ;;
        "n")
            show_logo_and_now_playing
            ;;
        "b"|"B")
            show_logo_and_now_playing
            ;;
        "m"|"M")
            show_startup_menu
            ;;
        "q")
            echo
            break
            ;;
    esac
    
    if $SHOULD_EXIT; then
        break
    fi
done

# Handle graceful exit
echo -e "${YELLOW}Thank you for listening!${NC}"
