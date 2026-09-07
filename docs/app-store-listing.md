# App Store listing

Everything App Store Connect asks for that is text, in one place, so the
submission form is filled in by pasting rather than by composing under a
deadline. Where a field has a limit the limit is in the heading.

What is still needed that is not text is at the bottom.

## Name (30)

Motionary App

## Subtitle (30)

Animated Home Screen widgets

## Promotional text (170)

A widget that plays, a wallpaper that carries the rest of the picture, and your
apps sitting on top of both. Your Home Screen, moving.

## Description (4000)

Motionary turns your Home Screen into one moving picture.

A design is a short clip, cut to fit a full-height widget, with app launchers
placed on it. The wallpaper behind the widget carries the rest of the scene, so
the two read as one continuous picture that fills the whole phone - and the
part inside the widget moves.

SET IT UP IN THREE STEPS
- Save the wallpaper to Photos from inside the app.
- Set it as your Home Screen wallpaper, with Perspective Zoom off.
- Add the Motionary widget to the top of a page.

MAKE IT YOURS
- Every spot on a design opens an app, a link or a search - change any of them.
- Swap the icon on a spot for one of hundreds of thousands of open-source
  icons, or leave a spot empty.
- Switch between designs with a swipe; the widget follows the app.
- Optionally let a tap on the empty space open your browser or a search page.

HOW IT WORKS
Motionary animates without any animation API: the frames are baked into the
widget itself and the system's own clock steps through them. The animation
keeps time with the wall clock, so the app and the widget always agree on what
is showing. Nothing runs in the background and nothing polls.

WHAT IT NEEDS
- Photos, add-only, to save the wallpaper for you to set.
- Local network, only if you use the optional companion Mac tool to send a
  design. The designs built into the app are ready to use as they are, and
  nothing about the app needs it.

Motionary has no account, no analytics and no advertising. Nothing about you
or your phone is collected or sent anywhere.

Note: a widget cannot open another app directly, so tapping a spot opens
Motionary for a moment before it opens the app. That is how every widget
launcher on iOS works.

## Keywords (100)

wallpaper,live,theme,icons,customize,aesthetic,launcher,motion,video,loop,gif,personalize,dynamic

## What's new (4000)

First release.

## Support URL

https://motionary-app.vercel.app

## Privacy policy URL

https://motionary-app.vercel.app/privacy

Both pages are `site/`, deployed to the `motionary` project on Vercel:
`cd site && vercel deploy --prod`. The About screen in the app links to the
same two pages (`AboutView.siteURL`), so the listing, the site and the app say
one thing.

## Privacy policy (the text at the URL above)

Motionary privacy policy

Motionary does not collect, store or transmit any personal information.

What the app accesses, and why:

- Photos (add only). When you save a wallpaper, Motionary writes one image
  to your photo library. It cannot read your existing photos.
- Local network. Only when Motionary is open and a design is being sent from
  Motionary Studio on a Mac on the same network. The app advertises a Bonjour
  service so the Mac can find the phone; nothing is sent from the phone.
- Calendar (optional, read only). Only if a design includes a calendar
  readout. The next event's title and time are read on the phone and drawn in
  the widget. They are never sent anywhere.
- Icon search. When you search for an icon, the words you type are sent to
  the public Iconify API (api.iconify.design) to find matching icons. Nothing
  else is sent, and the icons returned are kept on the phone.

Motionary has no accounts, no analytics, no advertising, and no third-party
SDKs. It does not track you across apps or websites.

Contact: the address in the app's About screen.

## App privacy questionnaire

- Do you or your third-party partners collect data from this app? **No.**

That single answer produces the "Data Not Collected" label. The Iconify search
is a request the person makes deliberately, the way a browser does, and the
words are not retained by the app; if a reviewer asks, that is the answer.

## Age rating

Every question: none / no. 4+.

## App Review notes

Motionary shows a design built into the app and places a widget that plays
it. To see it working:

1. Open the app. The welcome explains the three steps; skip it if you like.
2. Tap the save button (bottom right). Allow "Add Photos Only".
3. Settings > Wallpaper > Add New Wallpaper > Photos > the saved image. Set it
   for the Home Screen and turn Perspective Zoom off.
4. Touch and hold the Home Screen > Edit > Add Widget > Motionary. Add the
   tall widget at the top of a page.

The widget animates on its own within about a minute of being placed; the
system decides when to first draw it.

Local network permission: the app advertises a Bonjour service
(`_motionary._tcp`) while it is open so that Motionary Studio, a Mac app, can
send it a new design. Nothing is sent by the phone, and the feature is not
needed to use the app. There is no account and no server.

Tapping a spot on the widget briefly opens Motionary, which then opens the
chosen app. This is the only way a widget can launch a third-party app.

## Screenshots

`Tools/store-shots.sh` captures the 6.9" set (1320x2868) from the simulator,
including the Home Screen shot with the widget placed by SpringBoard. App
Store Connect derives the smaller sizes from that one.

## Not text, and still open

These are on the portal side and cannot be produced from this repository.
`docs/app-store-readiness.md` has the detail on each.

- **App Store distribution profiles** for `com.caden.Motionary` and
  `com.caden.Motionary.widget`. `Tools/archive.sh` stops at the export until
  they exist.
- **The recreated brand icons** in the starter designs. This is a legal
  question, not a technical one, and it is the item most likely to draw a
  rejection.
- **Mac availability.** iPhone apps are offered to Apple silicon Macs by
  default. The widget has no equivalent there; untick "Make this app
  available on Mac" in the App Store Connect pricing and availability page.
- **The licence and README** still say there is no App Store build and that
  the licence forbids one. As the copyright holder that does not bind you,
  but both should say what is true before the listing goes live.
