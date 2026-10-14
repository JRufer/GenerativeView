#!/usr/bin/env python3
"""Play clips through a libmpv bundle and check each decodes.

    tool/check-libmpv-bundle.py <bundle-dir> <clip>...

For each clip: the file must load, its video must reach the video output
(frames were decoded), any sound track must decode too, and playback must
run to the end without an error. Video and sound go nowhere (vo=null,
ao=null), so this needs no display or sound card.
"""
import ctypes
import os
import sys

# Event ids and end-file reasons, from mpv's client.h.
SHUTDOWN, END_FILE, FILE_LOADED, VIDEO_RECONFIG, AUDIO_RECONFIG = 1, 7, 8, 17, 18
EOF_REASON = 0


class Event(ctypes.Structure):
    _fields_ = [
        ("event_id", ctypes.c_int),
        ("error", ctypes.c_int),
        ("reply_userdata", ctypes.c_uint64),
        ("data", ctypes.c_void_p),
    ]


class EndFile(ctypes.Structure):
    _fields_ = [("reason", ctypes.c_int), ("error", ctypes.c_int)]


def main() -> int:
    bundle, clips = sys.argv[1], sys.argv[2:]
    mpv = ctypes.CDLL(os.path.join(os.path.abspath(bundle), "libmpv.so.2"))
    mpv.mpv_create.restype = ctypes.c_void_p
    mpv.mpv_wait_event.restype = ctypes.POINTER(Event)
    mpv.mpv_wait_event.argtypes = [ctypes.c_void_p, ctypes.c_double]
    mpv.mpv_get_property_string.restype = ctypes.c_void_p
    mpv.mpv_get_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    mpv.mpv_set_option_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    mpv.mpv_initialize.argtypes = [ctypes.c_void_p]
    mpv.mpv_command.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p)]
    mpv.mpv_free.argtypes = [ctypes.c_void_p]
    mpv.mpv_terminate_destroy.argtypes = [ctypes.c_void_p]

    def prop(handle, name: str) -> str:
        p = mpv.mpv_get_property_string(handle, name.encode())
        if not p:
            return ""
        value = ctypes.string_at(p).decode()
        mpv.mpv_free(p)
        return value

    failures = 0
    for clip in clips:
        handle = mpv.mpv_create()
        for key, value in (("vo", "null"), ("ao", "null"), ("hwdec", "no"), ("terminal", "no")):
            mpv.mpv_set_option_string(handle, key.encode(), value.encode())
        mpv.mpv_initialize(handle)
        args = (ctypes.c_char_p * 3)(b"loadfile", clip.encode(), None)
        mpv.mpv_command(handle, args)
        loaded = decoded = sounded = False
        video = audio = ""
        problem = "timed out"
        while True:
            event = mpv.mpv_wait_event(handle, 20.0).contents
            if event.event_id == 0:
                break
            if event.event_id == FILE_LOADED:
                loaded = True
                video = prop(handle, "current-tracks/video/codec")
                audio = prop(handle, "current-tracks/audio/codec")
            elif event.event_id == VIDEO_RECONFIG and prop(handle, "video-params/w"):
                decoded = True
            elif event.event_id == AUDIO_RECONFIG and prop(handle, "audio-params/samplerate"):
                sounded = True
            elif event.event_id == END_FILE:
                end = ctypes.cast(event.data, ctypes.POINTER(EndFile)).contents
                problem = "" if end.reason == EOF_REASON and end.error == 0 else f"ended with reason {end.reason}, error {end.error}"
                break
            elif event.event_id == SHUTDOWN:
                problem = "shut down"
                break
        mpv.mpv_terminate_destroy(handle)
        name = os.path.basename(clip)
        if not loaded:
            problem = problem or "did not load"
        elif not decoded:
            problem = problem or "no video frames decoded"
        elif audio and not sounded:
            problem = problem or "its sound was not decoded"
        if problem:
            failures += 1
            print(f"::error::{name}: {problem} (video {video or '-'}, audio {audio or '-'})")
        else:
            print(f"ok   {name}: video {video}, audio {audio or 'none'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
