# Third-pass prompts
Tool: built-in image_gen.
Primary reference: user-provided web-app screenshot, codex-clipboard-190234ab-65d8-4000-b126-dce741d2dea2.png.
Secondary reference: ../2026-10-08/pass-02/01-conversation-and-approval-light.png.

## Home and navigation
```text
Use case: ui-mockup.
Asset: third design pass for a personal native iPhone companion to DeepSeek Harness.
Input images: Image 1 is the user's ACTUAL DeepSeek Harness web app, the PRIMARY reference for brand, color, navigation and feature identity. Image 2 is our earlier iPhone concept, SECONDARY reference only for clear typography and phone-friendly rounded cards. Combine them. Do not copy image 2's light palette. The result should unmistakably feel like the user's DeepSeek Harness web app adapted carefully to iPhone.
Create ONE landscape 3:2 mockup board with TWO large straight-on, completely visible iPhones, dark mode. LEFT: home/new session in a selected workspace. RIGHT: workspace and navigation drawer. Slim realistic phone frames, 9:41 status bar, Dynamic Island and home indicator, unobtrusive charcoal-gray backdrop. Small board heading "DeepSeek Harness · iPhone" and subtitle "The same workspace, made for your phone". No hands, no perspective, no decorative sci-fi objects.
Visual identity from primary reference: almost-black #141416 main canvas, sidebar #1D1D1F, graphite #2A2A2D cards, white labels, gray secondary text, restrained desaturated slate-blue send button; tiny whale logo and "deepseek" wordmark followed by outlined little "HARNESS" tag as in reference. Compact regular typography and fine line icons, calm restrained density, generous mobile tap targets ~44pt. Rounded cards and composer at ~20pt radius; desktop chrome translated to phone, never miniaturized unreadable desktop.
LEFT PHONE HOME:
Native topbar with sidebar glyph left, compact actual "deepseek HARNESS" identity in center, ellipsis right. Below this a small host row "Patrick’s Mac" and green dot plus "Connected".
Small muted workspace breadcrumb with folder icon "dsh-mobile".
Upper-middle, plenty of breathing room: small white whale icon and main title "Into the Unknown", small slate "Preview" pill.
Then a very clear compact workspace selector "dsh-mobile" with folder and chevron, and "Standard mode" selector with branching icon and chevron. They can stack if needed on phone.
Large inviting graphite composer with exact placeholder "What would you like to work on?". Bottom row inside composer: plus icon, compact "DeepSeek" selector, slate-blue circular send arrow.
Below, heading "Continue a session".
Two tasteful rounded graphite cards with comfortable padding:
card 1: title "Reconnect handling"; secondary "Checking the recovery flow"; small green dot and "Running"; right chevron.
card 2: title "Polish the mobile UI"; secondary "Your draft is saved"; right chevron.
Near bottom a quiet outline action "View all sessions" with right arrow. No permanent tab bar, no huge dashboard counters. The New Session purpose should be obvious from home composer without adding excessive buttons.
RIGHT PHONE DRAWER:
Native nearly full-height drawer/sheet, slim glimpse of the underlying chat on right, same dark identity. Top compact "deepseek HARNESS" brand and close x.
Full-width graphite rounded "＋ New session" button.
Four compact native rows copied from the desktop reference: "Plugins", "Scheduled tasks", "MCP", "Usage", each with appropriate fine line glyph. No counts or fake analytics.
Thin divider.
"Workspaces" header with small search icon.
A comfortable list with folder icons: "chats", "eve-connect", "gaia", "homelab", "research", "dsh-mobile". Highlight dsh-mobile in a subtle graphite row; expand it to show two slightly indented conversation rows: "Reconnect handling" with tiny green running dot; "Polish the mobile UI" with muted draft indicator.
Bottom anchored area: laptop glyph and "Patrick’s Mac" with green dot and "Connected", then "Settings" with gear icon.
Exact two phones. All text should be easily readable. Keep spacing airy enough for iPhone yet retain the web app's character. No light-mode screen, no OpenAI or Codex branding, no bright neon, no large gradient panels, no network IP addresses, no debug text, no watermarks. These are proposed concept features including New session and compact management entry points.
```

## Conversation and recovery
```text
Use case: ui-mockup.
Asset: third design pass for native iPhone DeepSeek Harness, combining the user's actual web identity with polished phone-friendly cards and honest connection recovery.
Input images: Image 1 is the actual web UI, PRIMARY visual reference (whale, deepseek HARNESS wordmark, near-black canvas, graphite controls, slate-blue accent). Image 2 is the earlier phone concept, SECONDARY reference for good card sizing. Recreate the web app's character on phone, do not use the light palette.
Create a landscape 3:2 board with TWO large front-facing complete iPhones. Both DARK MODE. Left shows connected active chat. Right shows the SAME conversation while temporarily disconnected and recovering. The phone screens must make sense as successive app states. Clear readable 17pt-equivalent copy and thumb-sized buttons. Very dark gray neutral backdrop. Small board heading "DeepSeek Harness · iPhone"; subtitle "Keep the context. Recover the connection." Captions under phones "Connected" and "Recovering".
Color system: canvas #141416, cards #262629, white text, gray secondary copy, muted slate-blue primary send/approve controls. Tiny whale brand mark. Amber is reserved for lost connectivity or approval. No bright blue chat bubbles, no neon, no gradients. Large reading area, compact toolbar, native safe areas and 9:41 status bar with Dynamic Island.
LEFT CHAT:
Topbar sidebar glyph left, title "Reconnect handling", smaller "dsh-mobile" below, ellipsis right. Quiet thin host line "Patrick’s Mac" with green dot plus "Connected".
Right-aligned graphite user message "Keep my draft when the connection drops."
Unboxed assistant reply with two natural paragraphs:
"I found the connection problem."
"The app needs to reopen the stream when you return, then catch up on the conversation."
One compact well-designed rounded graphite tool card with thin border: small terminal glyph, title "Inspect reconnect flow", secondary "2 files checked", trailing chevron.
A second compact rounded approval card below with tiny amber dot and label "Your approval", heading "Apply the recovery changes?", secondary "Reconnect the session and preserve your draft.", small "View action details" disclosure. Two clear side-by-side actions "Allow once" in muted slate-blue and "Reject" in graphite outlined style. No always-allow.
Above anchored composer a very compact text selector "dsh-mobile ▾" then "Standard mode ▾".
Composer rounded graphite with "Message…" placeholder, plus at bottom left, compact "DeepSeek ▾" next to it, upward arrow at right. Fit with breathing room, do not compress text.
RIGHT RECOVERY:
Same navigation header and same workspace title.
Replace host status line with small amber reconnect icon and text "Reconnecting to Patrick’s Mac…". NEVER show Connected or green live status on this screen.
The user message and both assistant paragraphs remain visible as cached conversation content, fully readable, not erased, slightly muted only. Tool card "Inspect reconnect flow" / "2 files checked" remains present.
Instead of live approval buttons, show a concise friendly graphite status card with small amber connection icon:
"Connection interrupted"
"Last update 1 minute ago."
"Your draft is saved on this iPhone."
Text button "Connection details".
No big blocking modal, no full-screen spinner, no claim that work is still running or Mac sleeping because that is unknown offline.
Near bottom of content, a subdued note "Reconnecting automatically…" with small spinner. Do not duplicate warning banners elsewhere.
Fixed composer contains an actual unsent draft: "Also check what happens when I switch apps." Plus and "DeepSeek ▾" stay; send arrow is visibly disabled gray. Small note under composer "Send when reconnected". Keep draft editable, no keyboard shown.
Constraints: exactly two readable screens, one honest connected state and one reconnect state. Cards are the polished mobile component the user liked; preserve them while retaining desktop brand. No fake metrics, no backend implementation jargon, no "keep connected" switch, no spurious credential-expired alert, no new IP address input. No ratings icons or watermarks. All activity text is illustrative design content.
```

