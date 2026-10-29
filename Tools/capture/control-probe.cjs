const req = require('module').createRequire(__dirname + '/package.json')
const WebSocket = req('ws')
const [SID, TOKEN] = process.argv.slice(2)
const ws = new WebSocket('wss://192.0.2.10:3443/api/remote.mux', {
  headers: { Authorization: 'Bearer ' + TOKEN }, rejectUnauthorized: false })
let n = 0
ws.on('open', () => {
  // Deliberately empty args: the rejection should name every field it wants.
  ws.send(JSON.stringify({ type: 'open', streamId: '3', endpoint: 'session/control', payload: { args: {} } }))
})
ws.on('message', (d) => {
  const m = JSON.parse(String(d)); n++
  if (m.type === 'error') { console.log('ERROR', JSON.stringify(m.error).slice(0, 300)); return }
  const v = m.value ?? {}
  console.log('#' + n, m.type, v.type ?? '', JSON.stringify(v).slice(0, 300))
})
ws.on('error', (e) => console.log('ERR', e.message))
setTimeout(() => { console.log('frames:', n); process.exit(0) }, 10000)
