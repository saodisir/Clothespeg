<p align="center">
  <a href="README.md">简体中文</a> &nbsp;·&nbsp; English
</p>

<p align="center">
  <b>Clothespeg</b><br>
  One line strings together a clipboard and a notebook.
</p>

<p align="center">
  Free and open source · macOS 14 and later · <a href="#credits">built on Tendedero</a>
</p>

Clothespeg takes its name — and its idea — from Tendedero, Spanish for
clothesline. One line holds a clipboard and a notebook: screenshots, text and
folders you copy hang on it, ready when you are; notes hang there too, for
ideas and to-dos, in view the moment you look up. Rest the pointer at the
notch and the line drops down; move away and it rolls up, without breaking
whatever you were doing.

## The clipboard line

The text, code, colours, links, pictures and files you copy each become their
own card: a colour card's background follows its value, pictures show as
thumbnails. The pill filter bar along the bottom makes filtering easy. How to
click, drag and take a card down — see
[Gestures at a glance](#gestures-at-a-glance) below.

<p align="center">
  <img src="website/shots/line-clipboard.png" width="720" alt="The clipboard line: folders, files, code, colours and links hanging on the same line">
</p>

## The notes line

Click + above the middle of the line to write a note. Lists, to-dos and ideas
hang on their own line, one keystroke away and in view whenever you look.
Every note picks its own background colour, which makes them easier to find.

<p align="center">
  <img src="website/shots/line-notes.png" width="720" alt="The notes line: to-dos, ideas, a schedule and a shopping list on the same line">
</p>

## Notes that keep time

A note can keep time too. Click the bell in its footer and pick a moment — in
fifteen minutes, in an hour, or one of your own — and a banner arrives when it
comes, with *Next* and the time left at the foot of the card. Have it repeat
daily, weekly or monthly and it comes round again. Once a one-off has rung the
card reads *Reminder arrived*; **Got it** takes the dot away. You can set one
while you write, without saving first.

## How it comes down

- **Notch dwell**: rest the pointer on the left half of the notch and the
  clipboard line slides down; the right half brings the notes line. It works
  over full-screen apps too. Three dwell speeds: 0.15 / 0.25 / 0.4 s.
- **Hotkeys**: ⌃⌥C for the clipboard and ⌃⌥N for notes by default, recordable
  to anything else, with a warning the moment a shortcut clashes.
- **Modifier flip**: hold the modifier key and the two halves swap — one
  gesture, two lines.

## Gestures at a glance

Every card on the line answers to the same set of gestures. No digging through
settings to find them — here is the whole list.

### On a card

| Gesture | What happens |
|---|---|
| **Hover** | The card lifts a little, and the ✕ at its top-left and the button at its top-right fade in |
| **Single click** | Copies to the clipboard, with a little *Copied* pill underneath. Notes are the exception: clicking a note doesn't copy — the click belongs to its tick boxes and scrolling |
| **Double click** | Pastes into the app you came from — it switches back for you and presses ⌘V. Without Accessibility granted, it falls back to copying only, and you paste yourself. Double-clicking a note opens it for editing |
| **Long press** | Opens the system Markup editor for pictures and PDFs; the thumbnail follows once you save. Cards that can't be annotated (text, folders…) fall back to copying |
| **Press and drag** | Drop it into any text field, chat or email to paste; drop it into a Finder folder to move the file for real, the card coming down with it; drop it on the Trash to delete; drop it nowhere and it flies back to the line |
| **Right click** | Opens the menu, described below |

### The card's corners

| Where | What it does |
|---|---|
| Top-left **✕** | Takes the card down: pictures inside the app's own folder go to the Trash, outside files just leave the line, the original untouched. **A pinned card keeps its ✕** — but asks first, and the card only goes when you say so |
| Top-right **magnifier** | Opens the preview window: pictures full size, text scrollable and selectable, documents like PDFs through Quick Look, a list when a card holds several files. On a link it opens the browser instead; on a folder, Finder |
| The note's **pencil** | Opens the note editor |
| The note's **bell**, in its footer | Opens the reminder panel: pick a time, decide whether it repeats |
| The note's **tick boxes** | Click to strike a line through; when everything is ticked the note fades but stays on the line |

### The right-click menu

Items come and go with the kind of card; the everyday ones:

- **Copy** — a text card offers the opposite of the *Copy with formatting*
  switch: the gestures follow the switch, the menu always keeps the other
  reading at hand.
- **Pin / Unpin** — a pinned card outlives the automatic cleanup and the
  clear-all; its ✕ stays where it always was, and asks before it takes the
  card down.
- **Open / Markup / Show in Finder** — Markup appears only for pictures and
  image PDFs, and hands them to the system editor.
- **Open in Browser** — for link cards.
- **Save to Desktop** — pictures are copied there, text becomes a .txt.
- **Discard / Move to Trash** — pictures from the app's folder are discarded,
  outside files go to the Trash. A pinned card isn't offered this: its way out
  is the ✕, and the ✕ asks first.

### The keyboard

| Keys | What they do |
|---|---|
| **⌃⌥C** | Brings the clipboard line down / up (recordable in Settings) |
| **⌃⌥N** | Brings the notes line down / up (ditto) |
| **⌘↩** (pointer over a card) | Opens that card's preview; again closes it |
| **Esc** | Closes the preview and the search field; in the note editor it saves and leaves |
| **⌘S** | Saves the note |

### The line itself

- **Scroll sideways** to page through the line; the ‹ › arrows on the pill
  turn one screen at a time, with the count in the middle.
- **The pill**: filter by kind (all / text / links / colours / pictures /
  files), search, watch only what is pinned, flip back through earlier days.
- **The + above the middle of the rope**: write a new note.
- **Rolling up**: click anywhere off the line, press the hotkey again, or just
  move the pointer away for a moment.
- **The menu bar icon**: filled while the clipboard is being watched, hollow
  when paused. Clicking it opens the menu: both lines, a new note, the
  monitoring switch, *Hang new screenshots*, Settings, Quit.

## The screenshot inbox

To send a system screenshot to the clipboard, macOS wants four keys held at
once: ⌃⌘⇧3 or ⌃⌘⇧4. Press the three alone and the capture lands on the
Desktop — the clipboard never hears of it.

Clothespeg does away with the fourth key. Turn on *Hang new screenshots* and
the system's own ⌘⇧3 / ⌘⇧4 capture goes straight onto the clipboard line,
ready the moment you take it — same habit, one less key. Screen recordings
(⌘⇧5) hang the same way, as file cards — drag one out and it is the
recording itself. The previous save location is stored and restored when the
switch goes off or the app quits. Nothing asks for permission, because the
folder watched is the app's own. Off by default; leave it off and nothing
changes.

## A staging shelf

A staging shelf? Copying is the shelf. Copy a file or folder and it hangs on
the line; drag it down into a chat, an email or a terminal when you need it.
No sidebar shelf parked on your screen — the line is the shelf. Copy several
things at once and they hang as one card; drag it out and they all copy.

## More details

- **Pin**: right-click and choose Pin. A pinned card never falls to the
  automatic cleanup, and you can filter the line down to just the pinned ones.
- **The pill**: filter by kind (all / text / link / colour / image / file),
  search, watch only what is pinned, and flip back through earlier days — all
  inside one small pill.
- **Right-click menu**: Open; system Markup (pictures and image PDFs go to the
  system editor, and the thumbnail updates when you save); Show in Finder;
  Save to Desktop (files are copied, text and links become .txt); links open
  in the browser. Deleting belongs to the × in the corner, and to nobody else.
- **Automatic cleanup**: pick a retention (7 / 14 / 30 / 90 days). Pinned
  cards stay.
- **Privacy**: no network, nothing sent anywhere. A password manager's copy is
  never hung — those mark themselves private, and Clothespeg respects that.
- **English and 简体中文**. The menu bar icon shows whether the clipboard is
  being watched.

## Install

1. Grab the DMG from [Releases](https://github.com/saodisir/Clothespeg/releases/latest),
   open it, drag Clothespeg into Applications.
2. The app is signed with a Developer ID but not notarized by Apple. On first
   launch macOS will step in: open **System Settings → Privacy & Security**
   and click **Open Anyway**.

Coming from 1.8.0 or earlier: 1.9.0 ships under a new app identity. Your
settings and the cards on the line come across on first launch, but
Accessibility has to be granted once more (double-click paste needs it). Delete
the old copy first — one Clothespeg on a Mac is enough.

## Build from source

```bash
git clone https://github.com/saodisir/Clothespeg.git
cd Clothespeg
scripts/build-app.sh debug    # try it on your own machine, ad hoc, needs no certificate
scripts/build-app.sh          # a release build (see below)
scripts/make-dmg.sh           # a release DMG
```

Needs the Swift toolchain that ships with Xcode. No dependencies beyond the
system frameworks.

The scripts do more than one line of `swift build`: a universal binary via
`lipo`, an SDK fallback (the Command Line Tools' macOS 27 SDK is missing a
SwiftUI macro plugin they need), the icon, and `Info.plist` with `LSUIElement`
so the app does not take a Dock slot. So the scripts are part of this being
buildable, not part of releasing it — without them a clone yields a bare
binary that does not run.

### Signing

The scripts sign with whatever this machine has, and name no company:

- a Developer ID is present → signed with it, and the certificate and its Team
  Identifier are printed
- nothing is there → signed ad hoc, opens on this machine only, and it says so

To say which certificate a release goes under, pass it in:

```bash
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
RELEASE_TEAM=TEAMID \
scripts/build-app.sh release && scripts/make-dmg.sh
```

A named certificate that is not in the keychain **stops the build** rather than
quietly falling back to a different one. `make-dmg.sh` must be given the same
one as `build-app.sh`, or the image is signed by something other than the app
inside it.

A certificate's name is not a secret and is not hidden anywhere: every app
signed with a Developer ID shows that company in Gatekeeper, and anyone can
read it with `codesign -dv`. The key stays on its own machine, and only that
machine can produce a signature.

Notarization needs notary credentials in the keychain
(`xcrun notarytool store-credentials clothespeg-notary ...`); with them the
script submits and staples automatically, without them it only signs.

## Buy the author a coffee

Clothespeg is free and open source — no ads, no paywall. If it has saved you
time, a coffee is the kindest way to say so.

<p align="center">
  <a href="https://cv4z8ffs.jsjform.com/p/j5Jhqc">
    <img src="website/coffee-qr.png" width="180" alt="QR code to buy the author a coffee">
  </a>
</p>

<p align="center">
  Scan the code, or <a href="https://cv4z8ffs.jsjform.com/p/j5Jhqc">open the donation page</a>
</p>

## Credits

Clothespeg began as a fork of **[Tendedero](https://github.com/alejandrobujan/tendedero)**
by [Alejandro Bujan](https://github.com/alejandrobujan). The
line, the clothespins, the glass and the way a card swings when it lands are
his work.

On that foundation, Clothespeg reworks the data model to hold content instead
of file paths, hangs text and pictures by default, and adds the notes line,
pinning, the pill, the opt-in screenshot inbox and system Markup from the
right-click menu.

## License

Two licences, because the code comes from two places:

- **Tendedero, the original, is MIT** — the rope, the clothespin, the glass
  and the swing of a card landing on the line are Alejandro Buján's work and
  **stay MIT, unchanged by this fork**. As published, it is in
  [LICENSE-MIT](LICENSE-MIT).
- **This fork is Apache License 2.0** — the data model, the notes rope, the
  pill, watching and hiding, the screenshot inbox, paging. Full text in
  [LICENSE](LICENSE), what changed in [NOTICE](NOTICE).

MIT permits its code to be redistributed under Apache-2.0, which is what makes
both true at once. **Where you are reading Alejandro Buján's work, MIT applies;
where you are reading the additions, Apache-2.0 does.**

The **licensor** for the Apache-2.0 half is **VIZWISE (HONGKONG) LIMITED**, also
the company a release is signed with — copyright and signature on the same
party, which is what keeps the patent grant in section 3 worth anything, since
only the copyright holder can give it.

You may use, change and redistribute freely, **including closed source and
commercially**. Apache-2.0 also gives an express **patent grant** (so the
licence cannot be used as a weapon in patent litigation against someone who
took this) and requires you to **state what you changed**.

The "Name and icon" restriction is not part of that licence: neither the
Tendedero nor the Clothespeg name or icon is granted here, a redistributed
version must use a different name and a different icon, and it must not
suggest it is endorsed by either author.

