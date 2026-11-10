#!/bin/bash
# 0.6 s of silence (22050 Hz, 16-bit mono) wakes the USB speaker so the start of the sound isn't clipped.
exec aplay -q -D plughw:CARD=PowerConf,DEV=0 -r 22050 -c 1 -f S16_LE -t raw < <(head -c 26460 /dev/zero; cat)
