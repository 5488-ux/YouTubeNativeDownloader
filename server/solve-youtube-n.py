#!/opt/ytdlp-php/bin/python
import json
import re
import sys

from yt_dlp import YoutubeDL
from yt_dlp.extractor.youtube import YoutubeIE
from yt_dlp.extractor.youtube.jsc._director import initialize_jsc_director
from yt_dlp.extractor.youtube.jsc.provider import (
    JsChallengeRequest,
    JsChallengeType,
    NChallengeInput,
)


def main() -> None:
    if len(sys.argv) != 4:
        raise ValueError("expected video_id, player_url and n challenge")

    video_id, player_url, challenge = sys.argv[1:]
    if not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
        raise ValueError("invalid video ID")
    if not re.fullmatch(
        r"https://www\.youtube\.com/s/player/[A-Za-z0-9_-]+/[^\s]+/base\.js",
        player_url,
    ):
        raise ValueError("invalid player URL")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,200}", challenge):
        raise ValueError("invalid n challenge")

    options = {
        "quiet": True,
        "no_warnings": True,
        "js_runtimes": {"deno": {"path": "/usr/local/bin/deno"}},
    }
    with YoutubeDL(options) as downloader:
        extractor = YoutubeIE(downloader)
        director = initialize_jsc_director(extractor)
        request = JsChallengeRequest(
            type=JsChallengeType.N,
            video_id=video_id,
            input=NChallengeInput(player_url=player_url, challenges=[challenge]),
        )
        for _, response in director.bulk_solve([request]):
            solved = response.output.results.get(challenge)
            if solved:
                print(json.dumps({"ok": True, "n": solved}, separators=(",", ":")))
                return
    raise RuntimeError("n challenge solver returned no result")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"ok": False, "message": str(error)[:400]}, separators=(",", ":")))
        raise SystemExit(1)
