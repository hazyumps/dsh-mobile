const req = require('module').createRequire(__dirname + '/package.json')
const WebSocket = req('ws')
const [SID, TOKEN, SHAPE] = process.argv.slice(2)
const argsFor = {
  address: { request: { address: { kind: 'session', sessionId: SID } } },
  agentId: { agentId: SID },
  sessionId: { sessionId: SID },
}[SHAPE]
const ws = new WebSocket('wss://10.1.0.138:3443/api/remote.mux', {
  headers: { Authorization: 'Bearer ' + TOKEN }, rejectUnauthorized: false })
let n = 0
ws.on('open', () => {
  console.log('opening attachWait with', SHAPE)
  ws.send(JSON.stringify({ type: 'open', streamId: '2', endpoint: 'userQuestions/attachWait', payload: { args: argsFor } }))
})
ws.on('message', (d) => {
  const m = JSON.parse(String(d)); n++
  if (m.type === 'error') { console.log('ERROR', JSON.stringify(m.error).slice(0, 200)); return }
  const v = m.value ?? {}
  console.log('#' + n, m.type, v.type ?? '', JSON.stringify(v).slice(0, 240))
})
ws.on('error', (e) => console.log('ERR', e.message))
setTimeout(() => { console.log('frames:', n); process.exit(0) }, 12000)
