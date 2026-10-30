#!/bin/sh
set -eu
cd "$(dirname "$0")"

[ $# -eq 1 ] || { echo "usage: $0 root@HOST" >&2; exit 1; }
HOST=$1

[ -f out/badapple_frames.txt ] || ./build.sh

CTL=$(mktemp -d)
trap 'ssh -o ControlPath="$CTL/s" -O exit "$HOST" 2>/dev/null; rm -rf "$CTL"' EXIT
SSH="ssh -o ControlMaster=auto -o ControlPath=$CTL/s -o ControlPersist=60"

$SSH "$HOST" 'mkdir -p /root/badapple && rm -f /root/badapple/*.wav /root/badapple/*_test.*'
scp -o ControlPath="$CTL/s" player.sh out/*.txt out/*.mp3 "$HOST:/root/badapple/"

$SSH "$HOST" sh -s <<'EOF'
set -eu
chmod +x /root/badapple/player.sh
ln -sf /root/badapple/player.sh /usr/local/bin/badapple

CONF=/etc/asound.conf
if grep -q 'pcm.speakermix' "$CONF" 2>/dev/null; then
	echo "dmix already set up"
elif grep -q 'pcm.mastervol' "$CONF" 2>/dev/null; then
	cp "$CONF" "$CONF.orig"
	awk '
	/^pcm\.mastervol/ {
		print "pcm.speakermix {"
		print "    type dmix"
		print "    ipc_key 0x4d4d5831"
		print "    ipc_perm 0666"
		print "    slave {"
		print "        pcm \"hw:0,0\""
		print "        format S16_LE"
		print "        rate 48000"
		print "        channels 2"
		print "        period_size 1024"
		print "        buffer_size 4096"
		print "    }"
		print "}"
		print ""
		inside = 1
	}
	inside && /slave\.pcm/ { sub(/"hw:0,0"/, "\"speakermix\"") }
	inside && /^}/ { inside = 0 }
	{ print }
	' "$CONF.orig" > "$CONF"
	echo "dmix added to $CONF, original saved as $CONF.orig"
	rc-service bluealsa-aplay restart >/dev/null 2>&1 || true
else
	echo "no pcm.mastervol in $CONF, dmix not set up: stop Bluetooth audio before playing"
fi

echo "installed, run: badapple"
EOF
