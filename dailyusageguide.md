your normal day (WSL primary, phone over Windows’ adb)

Start work (WSL):

cd ~/dev/pak_connect
pc-wsl-arrive        # pulls, pub get, analyze
# if it says “repo dirty”, either:
git add -A && git commit -m "wip"    # or
git stash push -u -m "auto"          # then rerun pc-wsl-arrive


Code + run on phone (WSL):

flutter run -d jnv4mnylbaxsq4so
# r = hot reload, R = hot restart, q = quit


Take a break / switch to Windows:

pc-wsl-leave          # commits WIP and pushes to localwin (+ origin if set)

using Windows (when you want to test/build there too)

Arrive (Windows PowerShell/PS7):

Set-Location C:\dev\pak_connect
C:\bin\pc-win-arrive.ps1   # pulls, pub get, analyze


Run on phone (Windows):

flutter run -d jnv4mnylbaxsq4so


Leave (Windows):

C:\bin\pc-win-leave.ps1


the “leave” on one side and “arrive” on the other keeps both repos in lockstep via the local bare mirror (localwin) and your GitHub origin (when online).

scenarios you’ll hit (and exactly what to do)
1) repo is dirty and pulls fail

You’ll see: “cannot pull with rebase: unstaged or index contains uncommitted changes”.

Fix (WSL or Windows):

git add -A
git commit -m "wip: before pull"
# or stash instead:
git stash push -u -m "auto"
git pull --rebase localwin || true
git pull --rebase origin   || true


Optional: make pc-wsl-arrive auto-stash (I gave you the snippet earlier).

2) formatter stops your commit (like your fmt.sh)

It reformats files, then tells you to re-commit.

Solution:

git add -A
git commit -m "chore: apply fmt changes"


You can run it manually anytime:

./fmt.sh && git add -A && git commit -m "chore: fmt"

3) analyzer complains about UI symbols (Text, Color, Icons, etc.)

That’s almost always missing imports:

import 'package:flutter/material.dart';


If it “comes and goes” between Windows/WSL, it was due to mixed SDKs/adb paths earlier. You’ve fixed that.

Re-run analysis:

flutter pub get
flutter analyze

4) Gradle/Dart “compiler exited unexpectedly” / exit 130

Usually a cache hiccup or an interrupted previous compile.

Fix:

flutter clean
rm -rf .dart_tool
flutter pub get
flutter run -d jnv4mnylbaxsq4so -v   # use -v if it fails so we can see the last lines

5) phone not detected in WSL randomly

Windows adb must be running; WSL is shimming to it.

On Windows:

& "$Env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" start-server


In WSL:

adb devices
flutter devices


Don’t run adb kill-server in WSL (your wrapper already prevents this).

6) totally offline (no GitHub)

You can still “leave/arrive”: both scripts push/pull to localwin (the bare mirror).

When back online, arrive/leave will also sync with origin.

7) restoring after a WSL nuke

Reinstall WSL + Flutter.

Clone or copy your repo again.

Add remote back:

git remote add localwin /mnt/c/git/repos/pak_connect.git
git pull localwin main   # or your current branch


Recreate the WSL helper scripts (the blocks I gave you) if needed.

8) switching branches mid-work
git add -A
git commit -m "wip"
git switch <branch>
pc-wsl-arrive

9) CRLF warnings on Windows files

We set .gitattributes, but you can also disable per-repo conversion:

git config core.autocrlf false


Then re-checkout if needed:

git rm --cached -r .
git reset --hard

tiny cheatsheet

Status (WSL):

pc-status


Status (Windows):

C:\bin\pc-status-win.ps1


Arrive / leave (WSL):

pc-wsl-arrive
pc-wsl-leave


Arrive / leave (Windows):

C:\bin\pc-win-arrive.ps1
C:\bin\pc-win-leave.ps1


Build/run quickly (WSL):

flutter run -d jnv4mnylbaxsq4so

mental model (so it “clicks”)

One real dev environment = WSL (Flutter SDK, Android SDK).

Windows adb provides the USB connection; WSL talks to it via shim.

Two working copies (WSL + Windows) stay in sync via:

localwin (C:\git\repos\pak_connect.git) — works offline

origin (GitHub) — your canonical remote

You can start work on either side, run “arrive”, code/run, then “leave”. No lock-in, no scary PATH drift, and your phone just works.