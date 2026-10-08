# Image-generation prompts

Tool: built-in image_gen; new generation, opaque backgrounds. No reference images.

## 01 — Sessions and conversation

```text
Use case: ui-mockup
Asset type: High fidelity iPhone UI concept board, image 1 of 2 for DSH Remote, a native SwiftUI companion that follows AI coding sessions running on the user's computer.
Primary request: Create one beautiful, practical interface design image with TWO large front-facing modern iPhone screens side by side: Sessions on the left, live Chat on the right. This is a proposed design, not a screenshot of existing software. Realistic readable mobile UI, professional restraint, iOS native feel, thoughtfully designed typography. Landscape board, about 3:2 aspect ratio, phones dominate the image and remain large enough to read.
Scene/backdrop: Flat very pale warm gray background, subtle shadow under slim charcoal phone frames. Tiny understated heading above phones "DSH Remote" and subtitle "Your harness, at hand". Small captions below phones "01 / Sessions" and "02 / Conversation". No hands, no desk, no decorative objects or perspective.
Style: contemporary understated Apple-style native productivity app. Dark mode in BOTH screens. Near black charcoal canvas, slightly lifted graphite surfaces, off-white text, blue accent for primary actions, amber only for waiting decisions, green only for live connection. Crisp SF Pro-like typography, generous line spacing, 20pt side insets, restrained rounding. Realistic status bar 9:41 and Dynamic Island, bottom home indicator, thumb-sized tap targets. No gradients, neon glow, overdesigned glass, dashboard charts or robot mascot.
LEFT PHONE, Sessions:
At top small host picker with laptop glyph and text "Patrick’s Mac" and chevron; below tiny green dot plus text "Connected". Small settings gear top right. Large heading "Sessions".
Rounded search field "Search conversations".
Small native filter pills: "All" selected, "Running", "Waiting".
Section label "NEEDS YOU" in subdued amber.
One attention card: amber outlined question/decision icon, bold "Reconnect behavior", subtitle "dsh-mobile · Waiting for approval", small right arrow.
Section label "DSH-MOBILE".
A row "Fix reconnect handling", short subtitle "Running tests", green status label "Running", timestamp "Now".
A row "Polish the chat screen", subtitle "Ready to continue", timestamp "24m".
Section label "GAIA".
A row "Review role routing", subtitle "Completed", timestamp "1h".
Keep space below rows, quiet bottom note "Sessions from your computer". No new-chat button, no tab bar.
RIGHT PHONE, Chat:
Native navigation top with back chevron plus "Sessions", centered short title "Reconnect handling", trailing circular ellipsis button.
Under title small "dsh-mobile" then connected badge and tappable "DeepSeek" model chip.
Conversation scroll body:
right-aligned slightly blue-tinted USER bubble with exact text "Fix reconnect and keep my draft intact."
left-aligned ASSISTANT text without surrounding chat bubble, exact text "I found where connection state stops updating. I’m checking the fix now."
A small collapsed disclosure "Reasoning" with chevron.
Two compact tool activity rows/cards, neutral graphite: checkmark "Read ConnectionCoordinator.swift" with secondary "Finished"; spinner "Run swift test" with secondary "Running". Both right chevrons.
Below, a short assistant sentence "Your draft will stay with this conversation."
Near the bottom visible subtle "Working…" label with small spinner.
Anchored bottom rounded composer with placeholder "Message the harness…" and a second slim toolbar line inside it: paperclip icon, slash command icon, at far right round blue upward arrow send button. Separate small stop-square icon near Working label, not a giant red button.
Do not add keyboard. Clear safe areas.
Constraints: exactly two phones, fully visible. Prioritize accurate readable text and believable layout. No invented numerical performance metrics, token counters, charts, huge logos, extra screens, implementation annotations or watermarks. Mockup content is illustrative. Consistent 44px-equivalent controls, no text overflowing or crowding.
```

## 02 — Approval and session details

```text
Use case: ui-mockup
Asset type: High fidelity iPhone UI concept board, image 2 of 2 for DSH Remote, a native SwiftUI companion to AI coding sessions running on a computer.
Primary request: Create one polished practical interface design image with TWO large front-facing modern iPhones side by side: focused approval screen in dark mode on the left, session details sheet in light mode on the right. These are proposed screens, not screenshots of existing software. Landscape about 3:2 aspect ratio. Make phones large and text legible.
Scene/backdrop: Flat very pale warm gray with slim charcoal phone frames and subtle shadows, no perspective. Tiny heading above phones "DSH Remote" and subtitle "Stay in control, wherever you are". Small captions below phones "03 / Approve an action" and "04 / Session details".
Design language: quiet native Apple productivity app; SF Pro-like typography, comfortable vertical rhythm, 20pt side insets, crisp labels, restrained rounded surfaces, native line icons, blue primary buttons, amber waiting indicator, green connected indicator. LEFT canvas near black charcoal with graphite surfaces and off-white text. RIGHT warm off-white canvas with white cards and dark text. Realistic status bar 9:41, Dynamic Island, home indicators, large touch targets. No gradients, neon, mascot or fancy dashboard.
LEFT PHONE:
A chat navigation header, back chevron "Sessions", title "Reconnect handling", tiny "dsh-mobile · Connected".
Visible short assistant text near top: "The fix is ready. I need your approval before applying it."
A generously sized rounded approval panel below with subtle amber status icon and uppercase small label "APPROVAL REQUIRED".
Large headline "Apply the reconnect fix?"
Secondary sentence "Update connection handling and preserve your draft."
Card section label "ACTION"; text "Edit 2 files".
Two readable neutral code-style rows:
"ConnectionCoordinator.swift"
"ChatView.swift"
Small folded disclosure row "View action details" and chevron.
Small context line "Requested by this session on Patrick’s Mac".
At bottom of the approval panel a large full-width blue button "Allow once" and then bordered gray button "Reject". Both comfortably tappable. A small quiet line underneath "Applies to this action only."
Below panel an inactive composer showing "Answer the request to continue" in muted text. No always-allow switch, no auto-approval, no keyboard. All action details above buttons must be legible.
RIGHT PHONE:
Light-mode native full-height session details sheet, small drag indicator, title "Session details", circular close X in upper right.
Small workspace caption "dsh-mobile". Large heading "Reconnect handling".
Native grouped white card:
row "Model" with value "DeepSeek" and chevron
row "Host" with value "Patrick’s Mac"
row "Connection" with green dot and value "Connected"
Section heading "Goal"
White card containing "Recover cleanly after a connection drops."
Section heading "Tasks" and small right label "2 of 4".
White grouped checklist:
completed green check "Trace connection state"
completed green check "Prepare the fix"
empty circle "Run regression tests"
empty circle "Verify on iPhone"
Section heading "Plan"
White summary card "Keep drafts local, reconnect to the host, then refresh the conversation." with right chevron.
Small quiet note at bottom "Progress from the harness". No editable goals or drag handles on tasks. Bottom subtle link "Connection details".
Constraints: exactly two fully visible phones. Believable native screens, no impossible cramped text, typography prioritized. No invented usage or performance metrics. No extra tabs, no robot art, no watermark, no web page chrome. Numerical progress is illustrative mock data. Keep UI consistent between the dark and light variants.
```

