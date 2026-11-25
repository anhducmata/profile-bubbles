#!/usr/bin/env python3
"""Download well-known meme sounds (international and Vietnamese) for the agent bubble sounds.

    python3 scripts/get-meme-sounds.py

The clips come from the public soundboard Myinstants (https://www.myinstants.com), where users
upload them. They are saved into the app's own sounds folder,
~/Library/Application Support/ProfileBubbles/sounds, where Settings lists them as "Meme - …" and
"Meme VN - …". Many are cut from films, games and videos that belong to others, so they are for
your own use on your Mac and are not part of this repository. Lines with swearing were left out.
"""
import os
import time
import urllib.request

BASE = "https://www.myinstants.com/media/sounds/"
OUT = os.path.expanduser("~/Library/Application Support/ProfileBubbles/sounds")

# name shown in Settings -> file on the site
SOUNDS = {
    # international
    "Meme - Vine boom": "vine-boom.mp3",
    "Meme - Bruh": "movie_1.mp3",
    "Meme - Emotional damage": "emotional-damage.mp3",
    "Meme - Metal Gear alert": "metalgearsolid.mp3",
    "Meme - FBI open up": "fbi-open-up-sfx.mp3",
    "Meme - Windows XP error": "windows-xp-error-sound.mp3",
    "Meme - Huh cat": "huh-cat.mp3",
    "Meme - Among Us start": "among-us-start-sound.mp3",
    "Meme - Noice": "click-nice.mp3",
    "Meme - Anime wow": "anime-wow-sound-effect.mp3",
    "Meme - Yippee": "engineer_cheers07.mp3",
    "Meme - Mission passed": "gta-san-andreas-mission-complete-sound-hq.mp3",
    "Meme - Sad trombone": "sadtrombone.swf.mp3",
    "Meme - Nani sore": "nani-soreeeee.mp3",
    "Meme - Oh no no no": "whoa-no-no.mp3",
    "Meme - What the hell oh my god": "what-the-hell-oh-my-god-no-way-speed-up.mp3",
    # Vietnamese
    "Meme VN - Ối dồi ôi": "y2mate-mp3cut_d1tt0z9.mp3",
    "Meme VN - Khá Bảnh ảo thật đấy": "kha-banh-ao-that-day.mp3",
    "Meme VN - Ảo thật đấy": "ao-that-day.mp3",
    "Meme VN - Đấy nó phải thế chứ": "day-no-phai-the-chu-li-thang-nay-kha-va-gioi.mp3",
    "Meme VN - Đấy tôi biết ngay": "day-toi-biet-ngay.mp3",
    "Meme VN - Rambo nói thế thì chịu": "rambo-noi-the-thi-chiu-roi.mp3",
    "Meme VN - Ủa j zợ": "ua-j-zo.mp3",
    "Meme VN - Hong biết nữa": "hong-biet-nua-hong-co-nho_OqrKxVX.mp3",
    "Meme VN - Đi anh em": "di-anh-em.mp3",
    "Meme VN - Anh em xử lý": "anh-em-xu-lo.mp3",
    "Meme VN - Bạn cay không": "ban-cay-khong-kho-chiu-khong-khoc-de_xTW4U8q.mp3",
    "Meme VN - Ơ ơ ơ": "o-o-o.mp3",
    "Meme VN - Hi Linda xin chào": "hi-linda-xin-chao-ca-nha.mp3",
    "Meme VN - Nhạc xổ số": "nhac-xo-so.mp3",
    "Meme VN - Nhạc chuông Zalo": "nhac-chuong-zalo-cuoc-goi-den.mp3",
}

os.makedirs(OUT, exist_ok=True)
failed = 0
for name, file in SOUNDS.items():
    target = os.path.join(OUT, name + ".mp3")
    if os.path.exists(target):
        print(f"have  {name}")
        continue
    request = urllib.request.Request(BASE + file, headers={"User-Agent": "Mozilla/5.0", "Referer": "https://www.myinstants.com/"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read()
        if not data.startswith((b"ID3", b"\xff")):
            raise ValueError("not an mp3")
        with open(target, "wb") as f:
            f.write(data)
        print(f"got   {name}")
    except Exception as error:   # keep going: one missing clip should not stop the rest
        failed += 1
        print(f"FAIL  {name}: {error}")
    time.sleep(0.3)   # be gentle with the site
print(f"Saved to {OUT}" + (f", {failed} failed" if failed else ""))
