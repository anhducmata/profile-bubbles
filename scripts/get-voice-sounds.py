#!/usr/bin/env python3
"""Download anime-style girl voice lines for the agent bubble sounds.

    python3 scripts/get-voice-sounds.py

The lines are recorded by a voice actress and published by 効果音ラボ (Sound Effect Lab,
https://soundeffect-lab.info/sound/voice/line-girl1.html), free to use including commercially,
with no credit required. They are saved into the app's own sounds folder,
~/Library/Application Support/ProfileBubbles/sounds, where Settings lists them as "Girl - …".
The files are not part of this repository: the site's terms do not allow passing the raw
material on, so each user downloads their own copy.
"""
import os
import time
import urllib.request

PAGE = "https://soundeffect-lab.info/sound/voice/line-girl1.html"
BASE = "https://soundeffect-lab.info/sound/voice/mp3/line-girl1/line-girl1-"
OUT = os.path.expanduser("~/Library/Application Support/ProfileBubbles/sounds")

# name shown in Settings -> (file on the site, what she says)
LINES = {
    # good for "finished"
    "Girl - Yattaa": ("yattaa1", "やったーー！ yay!"),
    "Girl - Yatta ne": ("yattane1", "やったね！ we did it!"),
    "Girl - Banzai": ("banzai1", "ばんざーい！ hooray!"),
    "Girl - Panpakapaan": ("panpakapan1", "ぱんぱかぱーん！ ta-da!"),
    "Girl - Otsukaresama deshita": ("otsukaresamadeshita1", "お疲れ様でした good work"),
    "Girl - Ehehe": ("ehehe1", "えへへ… hehe"),
    "Girl - Hirameita": ("hirameita1", "ひらめいた！ I've got it!"),
    "Girl - Uwaa": ("uwaa1", "うわあ♪ wow"),
    "Girl - Wao": ("wow1", "わお！ wow!"),
    "Girl - Hai haai": ("haihaai1", "はいは～い♪ okay okay"),
    "Girl - Kekka wo happyou": ("kekkawohappyoushimasu1", "結果を発表します here are the results"),
    # good for "needs you"
    "Girl - Chotto matte": ("chottomatte1", "ちょっと待って wait a moment"),
    "Girl - Yobimashita": ("yobimashita1", "呼びました？ did you call?"),
    "Girl - Yonda kana": ("yondakana1", "呼んだかな？ did you call me?"),
    "Girl - Are": ("are1", "あれっ？ huh?"),
    "Girl - Nn": ("nn1", "ん～？ hm?"),
    "Girl - Eee": ("ee1", "えーーーっ！？ whaaat!?"),
    "Girl - Kora": ("kora1", "こら！ hey!"),
    "Girl - Jii": ("zii1", "じぃ～… staaare"),
    "Girl - Pinpon panpon": ("pinponpanpon1", "ぴーんぽーんぱーんぽーん announcement chime"),
    "Girl - Goannai": ("okyakusamanigoannai1", "お客様にご案内いたします an announcement for you"),
    "Girl - Kinkyuu jitai": ("kinkyuuzitaihassei1", "緊急事態発生！ emergency!"),
    "Girl - Chotto mazui kamo": ("chottomazuikamo1", "ちょっとマズイかも… this might be bad"),
    "Girl - Ganbatte": ("ganbatte1", "頑張って！ do your best!"),
    "Girl - Nyaa": ("nyaa1", "にゃー meow"),
}

os.makedirs(OUT, exist_ok=True)
failed = 0
for name, (file, says) in LINES.items():
    target = os.path.join(OUT, name + ".mp3")
    if os.path.exists(target):
        print(f"have  {name}")
        continue
    # The site serves its files only to downloads that come from its own page.
    request = urllib.request.Request(BASE + file + ".mp3", headers={"User-Agent": "Mozilla/5.0", "Referer": PAGE})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            data = response.read()
        if not data.startswith((b"ID3", b"\xff")):
            raise ValueError("not an mp3")
        with open(target, "wb") as f:
            f.write(data)
        print(f"got   {name}  ({says})")
    except Exception as error:   # keep going: one missing line should not stop the rest
        failed += 1
        print(f"FAIL  {name}: {error}")
    time.sleep(0.3)   # be gentle with the site
print(f"Saved to {OUT}" + (f", {failed} failed" if failed else ""))
