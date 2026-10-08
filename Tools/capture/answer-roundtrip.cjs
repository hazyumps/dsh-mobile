const req = require('module').createRequire(__dirname + '/package.json')
const WebSocket = req('ws')
const [SID, TOKEN] = process.argv.slice(2)
let answered = false
const ws = new WebSocket('wss://10.1.0.138:3443/api/remote.mux', {
  headers: { Authorization: 'Bearer ' + TOKEN }, rejectUnauthorized: false })
const collect = async (ev) => {
  if (!ev || ev.type !== 'tool/call') return
  const data = ev.data || {}
  if (data.name !== 'ask_user_question' || answered) return
  answered = true
  const q = JSON.parse(data.arguments).questions[0]
  console.log('QUESTION:', q.id, '|', q.question)
  const body = { type: 'client-request', rpcId: 'ans', method: 'userQuestions/answer',
    payload: { args: { agentId: SID, callId: data.callId,
      answer: { answers: [{ id: q.id, selected: ['Blue'] }] } } } }
  const r = await fetch('https://10.1.0.138:3443/api/userQuestions/answer', {
    method: 'POST', headers: { Authorization: 'Bearer ' + TOKEN, 'Content-Type': 'application/json' },
    body: JSON.stringify(body) })
  console.log('ANSWER ->', (await r.text()).slice(0, 160))
}
ws.on('open', () => ws.send(JSON.stringify({ type: 'open', streamId: '1', endpoint: 'session/follow',
  payload: { args: { request: { address: { kind: 'session', sessionId: SID }, assistantStream: true } } } })))
ws.on('message', async (d) => {
  const m = JSON.parse(String(d)); const v = m.value ?? {}
  if (v.type === 'snapshot') { for (const r of (v.records || [])) await collect(r.event) }
  if (v.type === 'event') { await collect(v.event); console.log('EVENT', v.event?.type) }
  if (v.type === 'assistant-stream') { const s = JSON.stringify(v); if (/you chose/i.test(s)) console.log('AGENT REPLIED:', s.slice(0, 200)) }
})
setTimeout(() => { console.log('answered:', answered); process.exit(0) }, 50000)
