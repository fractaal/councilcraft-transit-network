# For AI tooling
You may be asked to add/update new sounds (which are dfpwm files in ComputerCraft) that are generated via the convert-sounds.sh file
from the sound_sources folder.

The workflow here is:
Before the user asks, they may/should have already put the concerning files in `./sound_sources/`.
Check against the checked in files in ./sounds vs ./sound_sourecs/. Any diffs are the new files. Or the user may just mention. Confirm first before doing anything.

Once done, the user will probably include NL instructions/guidance about how/where they wanted this sound to be used/added -- as an arrival sequence, as a new feature, etc. etc. -- your job is to also wire this in properly as per existing patterns in the *.lua files.

This should be more or less what you need to do. TLDR:

- Examine new files in sound_sources
- Generate the appropriate dfpwms 
- Wire up properly as per patterns in the codebase (as of time of writing, pulled via GitHub Static.)

Do well!
