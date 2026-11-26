# Downloads configuration regression checks

Run `bash harness/downloads/build.sh` on macOS with Xcode selected. The executable uses the real
Downloads configuration hooks, wire parser and Premium transforms; Foundation-only test doubles stand
in for Spotify's task/delegate objects. It checks:

- Aggregate asset and unsupported custom task completions reach Spotify without crashing in an HTTP request getter.
- Split bootstrap/customize responses are buffered, rewritten and delivered once on completion.
- A cached response synthesized reentrantly during completion is rewritten and delivered immediately.
- Premium spoofing and offline configuration transforms retain both features in either order.
- Unknown attributes and unrecognized payloads pass through.
- A missing engine on Spotify 9.1.90 is distinguished from an unsupported Spotify version.
- An incompatible bridge is rejected and a compatible companion registered after the first lookup is found.

This verifies local hook behavior. An installed-device check is still needed for Spotify's offline
registration, download completion and playback without a connection.

Run `python3 -m unittest discover -s harness/downloads -p 'test_*.py'` for the IPA verifier's metadata
checks. For a real built IPA, run `python3 extension/Downloads/tools/verify_downloads.py path/to/Taurus.ipa`
to check the companion injection and the executable's actual guarded patch bytes.
