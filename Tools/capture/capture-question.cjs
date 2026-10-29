const req = require('module').createRequire(__dirname + '/package.json')
const WebSocket = req('ws')
const SID = process.argv[2], TOKEN = process.argv[3]
const ws = new WebSocket('wss://192.0.2.10:3443/api/remote.mux', {
  headers: { Authorization: 'Bearer ' + TOKEN }, rejectUnauthorized: false,
})
let seen = 0
ws.on('open', () => ws.send(JSON.stringify({ type: 'open', streamId: '1', endpoint: 'session/follow',
  payload: { args: { request: { address: { kind: 'session', sessionId: SID }, assistantStream: true } } } })))
ws.on('message', (d) => {
  const m = JSON.parse(String(d))
  if (m.type === 'error') { console.log('ERROR', JSON.stringify(m.error)); return }
  seen++
  const recs = m.value?.records ?? []
  console.log('frame', seen, 'records:', recs.length)
  for (const r of recs) {
    const ev = r.event ?? {}
    const s = JSON.stringify(ev)
    if (/tool|question/i.test(s)) {
      console.log('--- MATCH', ev.type, 'seq', ev.seq)
      console.log(s.slice(0, 2000))
    }
  }
  if (m.value?.type === 'event') {
    const ev = m.value.event ?? {}
    console.log('EVENT', ev.type, JSON.stringify(ev).slice(0, 1200))
  }
})
ws.on('error', (e) => console.log('ERR', e.message))
setTimeout(() => { console.log('frames:', seen); process.exit(0) }, 18000)
