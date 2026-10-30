#!/bin/sh

set -u

DIR=/root/badapple
VARIANT=
[ "${1:-}" = --orig ] && { VARIANT=_orig; shift; }
TEST=
[ "${1:-}" = --test ] && TEST=_test
FRAMES="${FRAMES:-$DIR/badapple_frames$VARIANT$TEST.txt}"
RING="${RING:-$DIR/badapple_ring$TEST.txt}"
AUDIO="${AUDIO:-$DIR/badapple$TEST.mp3}"
FPS="${FPS:-30}"
RING_FPS="${RING_FPS:-15}"
RING_BRIGHT="${RING_BRIGHT:-60}"
AV_DELAY_MS="${AV_DELAY_MS:-85}"
NOSOUND="${NOSOUND:-}"
NORING="${NORING:-}"
TITLE="${TITLE:-BAD APPLE}"
SCROLL_MS="${SCROLL_MS:-200}"

PIDFILE=/run/badapple.pid
LOG=/tmp/badapple.log
CLOCKDISP=/usr/local/bin/clockdisp
RINGLED=/usr/local/bin/ringled
LEDDIR=/sys/class/leds
DISPDEV=/sys/bus/platform/devices/display
BRIGHTFILE=$DISPDEV/brightness
SCROLLFILE=$DISPDEV/linedisp.0/scroll_step_ms
MESSAGE=$DISPDEV/linedisp.0/message
CURFILE=/sys/bus/i2c/devices/1-003c/current_divider

SELF=$(readlink -f "$0")

usage() {
	cat <<EOF
usage: badapple [--orig] [--test | --fg | --stop]

  badapple          play in the background
  badapple --fg     play in the foreground, Ctrl-C stops
  badapple --test   first 10 seconds, foreground
  badapple --stop   stop the background show
  --orig            original colours instead of inverted

environment: NOSOUND=1 NORING=1 RING_BRIGHT=60 AV_DELAY_MS=85
             TITLE='BAD APPLE' SCROLL_MS=200 FRAMES= RING= AUDIO=
EOF
}

running_pid() {
	[ -f "$PIDFILE" ] || return 1
	_pid=$(cat "$PIDFILE" 2>/dev/null)
	[ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null && echo "$_pid"
}

case "${1:-}" in
--stop)
	if pid=$(running_pid); then
		kill "$pid" && echo "stopped"
	else
		echo "not running"
	fi
	exit 0
	;;
--test|--fg)
	;;
--help|-h)
	usage
	exit 0
	;;
"")
	if pid=$(running_pid); then
		echo "already playing (pid $pid); badapple --stop to stop it"
		exit 1
	fi
	FRAMES=$FRAMES RING=$RING AUDIO=$AUDIO setsid nohup "$SELF" --fg >"$LOG" 2>&1 </dev/null &
	echo "playing in the background, log in $LOG; badapple --stop to stop"
	exit 0
	;;
*)
	usage
	exit 1
	;;
esac

[ -r "$FRAMES" ] || { echo "no frames file $FRAMES" >&2; exit 1; }
[ -n "$NOSOUND" ] || [ -r "$AUDIO" ] || { echo "no sound file $AUDIO" >&2; exit 1; }
[ -n "$NORING" ] || [ -r "$RING" ] || NORING=1

if pid=$(running_pid) && [ "$pid" != $$ ]; then
	echo "already playing (pid $pid)" >&2
	exit 1
fi
echo $$ > "$PIDFILE"

now_ms() {
	read _up _ < /proc/uptime
	NOW=$(( ${_up%.*}${_up#*.} * 10 ))
}

wait_slot() {
	_end=$(( t0 + $1 * 1000 / $2 ))
	now_ms
	[ "$NOW" -ge "$_end" ] && return 1
	_start=$(( t0 + ($1 - 1) * 1000 / $2 ))
	[ "$NOW" -lt "$_start" ] && usleep $(( (_start - NOW) * 1000 ))
	return 0
}

OLD_BRIGHT=$(cat "$BRIGHTFILE" 2>/dev/null)
OLD_CURRENT=$(cat "$CURFILE" 2>/dev/null)
OLD_SCROLL=$(cat "$SCROLLFILE" 2>/dev/null)
APLAY_PID=
RING_PID=

cleanup() {
	trap - EXIT INT TERM HUP
	[ -n "$APLAY_PID" ] && kill "$APLAY_PID" 2>/dev/null
	if [ -n "$RING_PID" ]; then
		kill "$RING_PID" 2>/dev/null
		wait "$RING_PID" 2>/dev/null
		sleep 0.1
	fi
	[ -n "$NORING" ] || $RINGLED off >/dev/null 2>&1
	$CLOCKDISP --off >/dev/null 2>&1
	[ -n "$OLD_SCROLL" ] && printf '%s' "$OLD_SCROLL" > "$SCROLLFILE" 2>/dev/null
	[ -n "$OLD_BRIGHT" ] && printf '%s' "$OLD_BRIGHT" > "$BRIGHTFILE" 2>/dev/null
	[ -n "$OLD_CURRENT" ] && printf '%s' "$OLD_CURRENT" > "$CURFILE" 2>/dev/null
	rm -f "$PIDFILE"
}
i=0
trap cleanup EXIT
trap 'echo "stopped by signal at frame $i"; exit 0' INT TERM HUP

SEGS=
for d in d1 d2 d3 d4; do
	for s in a b c d e f g; do
		SEGS="$SEGS $LEDDIR/clock:$d:$s/brightness"
	done
done
SEGS="$SEGS $LEDDIR/clock:colon:top/brightness $LEDDIR/clock:colon:bottom/brightness"

$CLOCKDISP --brightness 255 --current 2 --colon off >/dev/null 2>&1
[ -n "$NORING" ] || $RINGLED off >/dev/null 2>&1

if [ -n "$TITLE" ]; then
	msg="    $TITLE"
	printf '%s' "$SCROLL_MS" > "$SCROLLFILE"
	printf '%s' "$msg" > "$MESSAGE"
	usleep $(( ${#msg} * SCROLL_MS * 1000 ))
	$CLOCKDISP --off >/dev/null 2>&1
fi

if [ -z "$NOSOUND" ]; then
	mpg123 -q -s -r 48000 -e s16 "$AUDIO" | aplay -q -t raw -f S16_LE -c 2 -r 48000 &
	APLAY_PID=$!
	n=0
	while [ $n -lt 200 ]; do
		ls -l /proc/$APLAY_PID/fd 2>/dev/null | grep -q /dev/snd/pcm && break
		kill -0 $APLAY_PID 2>/dev/null || { echo "aplay failed, playing without sound"; APLAY_PID=; break; }
		usleep 10000
		n=$((n + 1))
	done
	now_ms
	t0=$((NOW + AV_DELAY_MS))
else
	now_ms
	t0=$NOW
fi

if [ -z "$NORING" ]; then
	(
		trap 'exit 0' TERM
		j=0
		shown=0
		prev=
		while IFS= read -r line; do
			j=$((j + 1))
			wait_slot $j "$RING_FPS" || continue
			shown=$((shown + 1))
			[ "$line" = "$prev" ] && continue
			prev=$line
			$RINGLED -b "$RING_BRIGHT" raw $line >/dev/null 2>&1
		done < "$RING"
		echo "ring frames $j, shown $shown, dropped $((j - shown))"
	) &
	RING_PID=$!
fi

drawn=0
prev=
while IFS= read -r line; do
	i=$((i + 1))
	wait_slot $i "$FPS" || continue
	drawn=$((drawn + 1))
	[ "$line" = "$prev" ] && continue
	prev=$line
	set -- $line
	for p in $SEGS; do
		printf '%s' "$1" > "$p"
		shift
	done
done < "$FRAMES"

now_ms
echo "frames $i, shown $drawn, dropped $((i - drawn)), finished $((NOW - (t0 + i * 1000 / FPS))) ms after schedule"

[ -n "$RING_PID" ] && wait "$RING_PID" 2>/dev/null
RING_PID=
[ -n "$APLAY_PID" ] && wait "$APLAY_PID" 2>/dev/null
APLAY_PID=
exit 0
