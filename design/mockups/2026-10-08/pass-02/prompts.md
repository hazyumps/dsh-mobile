# Second-pass image prompts
Tool: built-in image_gen.
Reference: ../01-sessions-and-chat.png from pass one (product context, not a layout to preserve).

## Light conversation and approval
```text
Use case: ui-mockup
Asset type: SECOND DESIGN PASS for DSH Remote, a native iPhone companion for an AI coding harness running on a Mac.
Reference image: the provided earlier mockup is CONTEXT ONLY: it establishes the product and realistic phone format. Redesign the interface substantially to feel calmer, more considered, conversation-led. Do NOT preserve the old many-card dashboard layout or heavy status labels.
Primary request: A high fidelity visual storyboard with TWO large front-facing iPhones on a pale warm off-white background. Both phones show LIGHT MODE versions of the SAME ongoing conversation, first following the work, then answering an approval inline. Give these screens the craft of a polished shipping chat app. This is a design concept with fictional example activity.
Composition: landscape 3:2 image, two straight-on slim black-bezel iPhones, no perspective, complete devices, large enough to read every sentence. Tiny upper-left board heading "DSH Remote / 02" and understated subtitle "Pick up where you left off". Under phones simple captions "Follow the work" and "Make the decision". No marketing flourish or gratuitous imagery.
Visual system: warm near-white #FAFAF8 canvas, near-black text, airy SF Pro-style typography, very restrained light-gray user bubbles and composer. Main body text ~17pt equivalent with comfortable line spacing, 22pt side margins. Almost all controls monochrome; small muted green connectivity dot and tiny amber approval indicator are the ONLY semantic colors. Primary action buttons near black with white text. No blue filled bubbles. No drop shadows inside the UI. No visible borders around ordinary assistant messages or tool activity. Rounded native composer, clear hierarchy, generous space without a huge blank gap. At most ONE card on approval phone, no cards on conversation phone besides user bubble and composer.
Both phones: realistic iPhone 9:41 status bar, Dynamic Island, black home indicator. Top toolbar: native sidebar icon left; centered "Reconnect handling", with small muted "dsh-mobile" below; ellipsis right. Thin pale separator only under toolbar. Tapping the title opens details, no large host/model badges at top.
LEFT, following work:
Just beneath header very small muted line "Patrick’s Mac" with tiny green dot and "Live" aligned right.
Right-aligned compact pale gray user bubble, black text: "Keep my draft when the connection drops."
Open unboxed assistant text below:
"I found where the draft is being lost."
Next paragraph: "The connection can recover, but the composer starts over. I’m keeping the draft with the conversation."
One quiet inline activity disclosure with small tool glyph, exact text "Read 3 files · Running tests" and right chevron. No card, no giant icons, no separate Working indicator elsewhere.
Below the disclosure a compact unboxed 3-line checklist: check "Trace draft state", check "Prepare the fix", small spinner "Check reconnect behavior". Hairline indent guide is optional, not colored bullets.
Subtle divider then another assistant line: "You can leave this open. The work continues on your Mac."
At bottom comfortable fixed composer: pale-gray softly rounded wide multiline surface. Placeholder "Message…" on first line, attachment plus button at lower left; small plain text "DeepSeek" and tiny down chevron beside it; at lower right near-black circular button with white stop square because agent is running. No extra toolbar, no tab bar, no microphone. Home-safe area.
RIGHT, same conversation at an approval step:
Same header, tiny green connected indicator, SAME light theme and same typography.
Compact user bubble same text.
Open assistant paragraph: "The fix is ready. Your draft will stay with this conversation when the connection drops."
Quiet one-line history disclosure "3 files read · Checks complete" and chevron.
Then integrate the approval into the conversation flow, NOT a modal or full-screen warning. One subtle near-white inset surface with only a very thin gray stroke, 18px corner radius. Tiny amber dot plus uppercase small "YOUR APPROVAL".
Heading "Apply this change?"
Text "Update draft storage and reconnect handling."
Two small stacked file rows, monospaced only for filenames: "ChatView.swift" and "ConnectionCoordinator.swift". Single link-like row "View action details" chevron.
One horizontal row of equally thumb-friendly buttons: near-black filled "Allow once" (wider) and outlined neutral "Reject".
Outside below panel muted note "Only this action is approved."
At bottom identical composer with "Message…" placeholder, plus and "DeepSeek" model selector, but idle pale send arrow button. No keyboard.
Constraints: Exactly two phones and fully legible realistic text. No gradients, shiny glass, glow, mascot, attention dashboard, oversized cards, fake metrics, extra navigation buttons, huge branding, geometric decoration, watermarks. Preserve generous reading width. Assistant replies always unboxed. The point is a natural conversation with tools and decisions folded into it.
```

## Dark conversation switcher and continuation
```text
Use case: ui-mockup
Asset type: SECOND DESIGN PASS for DSH Remote — companion board, dark appearance and conversation switching.
Reference image: earlier DSH Remote mockup is supplied for product context. Replace its dense panels, bright blue bubbles, and large connection/model badges with a minimal conversation-first design.
Primary request: two large front-facing iPhones side-by-side on a very pale warm-gray background. LEFT phone shows the conversation switcher as an almost full-width native sheet. RIGHT phone shows an ongoing conversation in dark mode after the user returns, with their saved draft ready. BOTH screens dark mode, coherent with an elegant light-mode sibling: typography and layout do the work, almost no chrome.
Composition: landscape 3:2 board, fully visible slim black phone frames, realistic 9:41 status bars, Dynamic Islands and home indicators. Very small board heading "DSH Remote / 02" with subtitle "One workspace, within reach". Captions below phones "Switch conversations" and "Continue naturally". No hands or desktop scene.
Design: dark charcoal #171717 background, warm-white text, muted gray supporting text, slight elevation only for composer and one active list row. Native SF Pro-like type. 22pt margins, 17pt equivalent body copy, strong readable contrast. Primary action near-white fill with charcoal symbol/text; a tiny green dot for connected and tiny amber dot for waiting. Almost monochrome, no bright blue UI. No gradients, glows or large boxes.
LEFT PHONE:
Native conversation switcher sheet open over a subtly visible sliver of the chat underneath, filling most of phone. Small drag indicator at top. Title "Conversations", circle close x at top right. Small top line laptop icon and "Patrick’s Mac" with downward chevron, then a quiet "Connected" green dot. This is where host management lives, not in the main conversation.
Borderless subtle rounded search input "Search".
Small section caption "NEEDS YOU". Plain row with tiny amber dot, title "Review role routing", supporting text "gaia · A question is waiting", right chevron. No amber card, no heavy background.
Small section caption "DSH-MOBILE". Three comfortable text rows separated only by whitespace:
"Reconnect handling" selected with very subtle graphite full-width row fill, secondary "Draft saved", tiny running indicator.
"Polish the chat screen", secondary "24 minutes ago".
"Pair the iPhone", secondary "Yesterday".
Section "GAIA" with row "Review role routing", secondary "1 hour ago".
Near bottom with plenty of room, small native rows "Pair another computer" with laptop-plus line icon, and "Settings" with gear icon. No New chat button, no tabs, no numerical charts. No URLs or fingerprints.
RIGHT PHONE:
Toolbar sidebar icon left, centered "Reconnect handling", small "dsh-mobile" below, ellipsis right. Tiny quiet "Patrick’s Mac" under header and green dot plus "Live" right.
Top visible user bubble in muted graphite: "Keep my draft when the connection drops."
Assistant open text, no bubble: "The change is applied."
Next paragraph: "Your draft now stays with this conversation. Reconnecting refreshes the messages without clearing what you’re typing."
Quiet collapsed activity row "2 files updated · Checks passed" with small checkmark and right chevron, no surrounding card.
Another assistant paragraph "Next, try switching away and coming back on your iPhone."
A few small copy and more icons below, gray and unobtrusive.
Lower in the conversation a very subtle centered pill "Back to latest" with down arrow: implies reader can control scrolling, not a marketing callout.
Anchored bottom rounded graphite composer shows an actual unsent saved draft: "Also check what happens when I switch apps." No placeholder. Small "Draft saved" muted text just above composer, app status not a speech bubble.
Inside composer bottom row: plus icon, plain "DeepSeek" and down chevron, trailing near-white filled round send arrow. No keyboard, no voice input. Comfortable home safe area.
Constraints: Exactly two realistic usable screens. Copy is illustrative concept content, not proof of implemented work. Conversation has generous reading width and distinct paragraphs. No huge status badges or panels. No duplicate Working indicators. No bright colored user bubbles. No large timestamps. Minimize chrome and visual noise. No watermark.
```

## Targeted correction to the dark board
```text
Edit this DSH Remote mockup with an extremely small targeted correction. On the RIGHT phone only, in the tiny message action toolbar immediately below the assistant response, remove the thumbs-up and thumbs-down rating icons. Keep just the copy icon and an ellipsis icon, next to one another with natural 20px spacing, left aligned at the original copy icon position. The app does not have ratings. Change nothing else at all: preserve every other pixel and all text, typography, spacing, background, phone frames, list, buttons, draft, headers, labels, light, colors and resolution. This is UI precision editing; do not redesign, relayout or re-render unrelated areas.
```

