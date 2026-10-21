#!/bin/sh
# Speech for the Talk noise bench (docs/voice.md §12), made with the Mac's own voices: the person's
# turns and interruptions, the Bot's reply, and the voices inside the noise (a TV, people talking
# across the room, a song). Nothing is downloaded; the clips stay out of the repository.
#   Tools/talk-bench/make-clips.sh build/talk-bench/clips
set -eu
out=${1:-build/talk-bench/clips}
mkdir -p "$out"
say_to() { say -v "$1" --file-format=WAVE --data-format=LEI16@16000 -o "$out/$2.wav" "$3"; }

# The person (Samantha), at the phone.
say_to Samantha turn "Check the NAS for me please."
say_to Samantha stop "Stop."
say_to Samantha wait "Wait, wait."
say_to Samantha holdon "Hold on."
say_to Samantha other "No, the other one."
say_to Samantha instead "Actually, check the backups instead."
say_to Samantha mmhm "Mm-hm."
say_to Samantha yeah "Yeah."

# The Bot's reply, in another voice.
say_to "Reed (English (US))" bot "The NAS is fine. Volume one is at sixty two percent, the snapshots ran at three this morning, and nothing failed overnight. The next scrub is on Sunday, and I'll tell you if anything changes before then."

# Voices inside the noise.
say_to Fred tv "And tonight in the news, storms move east across the plains, with heavy rain expected by Thursday. Officials say schools may close early, and drivers should plan for delays on the interstate."
say_to Kathy chatter1 "So I told him we could meet on Friday, but he said the office is closed, so maybe next week then."
say_to "Eddy (English (US))" chatter2 "Did you see the game last night? They were up by ten and then it all fell apart in the last quarter."
say_to "Flo (English (US))" chatter3 "I need to pick up the kids at four and then get groceries, do you want anything from the store?"
say_to "Good News" song "We are walking in the sunshine every morning, and the day is long and bright."
echo "clips in $out"
