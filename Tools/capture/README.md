# Capture and probe scripts

These talk to a live `dsh-relay` and a live harness. They are how every unknown
wire shape in this repo was learned, and they are kept here because they used to
live in `/tmp` and would have vanished.

```sh
cd Tools/capture && npm install ws     # the only dependency; Node's global
                                       # WebSocket cannot set an Authorization
node follow-session.cjs <session-id> <device-token>
```

- `follow-session.cjs` — opens `session/follow` and prints every frame and event
  type. Point it at a session that is doing something.
- `attachwait.cjs` — probes `userQuestions/attachWait` argument shapes.
- `control-probe.cjs` — opens `session/control`, which needs no arguments and
  streams goals, titles and usage.
- `answer-roundtrip.cjs` — asks a question, answers it, and prints what follows
  (`tool/result`, the next `assistant/message`, `turn/end`).

Devices: mint one through the pairing page and **revoke it when you are done**
(`POST /relay/devices/revoke`); an unrevoked device is a live credential.

`Tools/probes/*.swift` are standalone `swiftc` probes from the TLS-hang
investigation — they falsified the "URLSession never resumes the continuation"
theory that survived several rounds of reading.
