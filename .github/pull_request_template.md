## What this changes

<!-- One or two sentences. The diff shows the rest. -->

## Why

<!-- What was wrong, or what this makes possible. -->

## How it was verified

<!--
Most bugs here are invisible from inside the code: a widget that draws nothing
looks identical to a widget that is broken. Say what you actually looked at.
-->

- [ ] `xcodebuild -scheme Motionary -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MotionaryTests test`
- [ ] Tests added or updated for the behaviour that changed
- [ ] Looked at a rendered widget, if this touches rendering (`Tools/lab-shot.sh`)
- [ ] Rebuilt designs with `--rebuild-starred`, if this touches the pipeline

## Notes

<!--
Anything a reviewer would otherwise have to rediscover: a measurement, a number
that came from hardware, a route that was tried and did not work.
-->
