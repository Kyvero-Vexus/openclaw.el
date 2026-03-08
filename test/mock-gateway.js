#!/usr/bin/env node
/**
 * Mock OpenClaw gateway for E2E testing.
 * Simulates the real gateway protocol:
 * 1. Sends connect.challenge
 * 2. Accepts connect request
 * 3. Handles chat.send by replying with real-protocol streaming events
 * 4. Tests session list, chat.history
 *
 * Usage: node mock-gateway.js [port]
 * Default port: 18790
 */
const WebSocket = require('ws');
const crypto = require('crypto');

const PORT = parseInt(process.argv[2] || '18790', 10);
const SESSION_KEY = 'agent:test:main';
const AGENT_NAME = 'test';

const wss = new WebSocket.Server({ port: PORT });
console.log(`Mock gateway listening on ws://127.0.0.1:${PORT}`);

// Store sent messages so history works
const messageHistory = [];

wss.on('connection', (ws) => {
    console.log('[mock] Client connected');

    // Send challenge
    ws.send(JSON.stringify({
        type: 'event',
        event: 'connect.challenge',
        payload: { nonce: crypto.randomUUID(), ts: Date.now() }
    }));

    ws.on('message', (raw) => {
        let data;
        try { data = JSON.parse(raw.toString()); } catch { return; }

        console.log(`[mock] RECV: ${data.method || data.type} (id: ${data.id})`);

        switch (data.method) {
            case 'connect':
                ws.send(JSON.stringify({
                    type: 'res', id: data.id, ok: true,
                    payload: {
                        type: 'hello-ok',
                        protocol: 3,
                        server: { version: '0.0.1-mock', connId: crypto.randomUUID() },
                        features: {
                            methods: ['sessions.list', 'chat.send', 'chat.history'],
                            events: ['connect.challenge', 'agent', 'chat', 'tick']
                        },
                        tickIntervalMs: 30000
                    }
                }));
                break;

            case 'sessions.list':
                ws.send(JSON.stringify({
                    type: 'res', id: data.id, ok: true,
                    payload: {
                        sessions: [{
                            key: SESSION_KEY,
                            kind: 'direct',
                            displayName: 'E2E Test Session',
                            channel: 'webchat',
                            chatType: 'direct',
                            updatedAt: Date.now(),
                            sessionId: crypto.randomUUID(),
                            modelProvider: 'mock',
                            model: 'mock-model'
                        }]
                    }
                }));
                break;

            case 'chat.history':
                ws.send(JSON.stringify({
                    type: 'res', id: data.id, ok: true,
                    payload: { messages: messageHistory }
                }));
                break;

            case 'chat.send': {
                const msg = data.params?.message || '';
                const runId = crypto.randomUUID();
                const sessionKey = data.params?.sessionKey || SESSION_KEY;

                // Store user message in history
                messageHistory.push({
                    role: 'user',
                    content: [{ type: 'text', text: msg }],
                    timestamp: Date.now()
                });

                // Send response ack
                ws.send(JSON.stringify({
                    type: 'res', id: data.id, ok: true,
                    payload: { runId, status: 'started' }
                }));

                // Generate reply
                const reply = `echo: ${msg}`;

                // Send streaming in real-protocol format
                // lifecycle start
                ws.send(JSON.stringify({
                    type: 'event', event: 'agent',
                    payload: {
                        runId, stream: 'lifecycle',
                        data: { phase: 'start', startedAt: Date.now() },
                        sessionKey, seq: 1, ts: Date.now()
                    }
                }));

                // Stream deltas with accumulated text (real protocol style)
                let accumulated = '';
                const words = reply.split('');
                let seq = 2;
                let charIdx = 0;

                // Send chars in small batches to simulate streaming
                const batches = [];
                for (let i = 0; i < reply.length; i += 3) {
                    batches.push(reply.substring(0, i + 3));
                }
                // Always include full text as last batch
                if (batches[batches.length - 1] !== reply) {
                    batches.push(reply);
                }

                let batchIdx = 0;
                const sendNextBatch = () => {
                    if (batchIdx >= batches.length) {
                        // Send final
                        setTimeout(() => {
                            // agent lifecycle end
                            ws.send(JSON.stringify({
                                type: 'event', event: 'agent',
                                payload: {
                                    runId, stream: 'lifecycle',
                                    data: { phase: 'end', endedAt: Date.now() },
                                    sessionKey, seq: seq++, ts: Date.now()
                                }
                            }));

                            // chat final
                            ws.send(JSON.stringify({
                                type: 'event', event: 'chat',
                                payload: {
                                    runId, sessionKey, seq: seq,
                                    state: 'final',
                                    message: {
                                        role: 'assistant',
                                        content: [{ type: 'text', text: reply }],
                                        timestamp: Date.now()
                                    }
                                }
                            }));

                            // Store assistant message in history
                            messageHistory.push({
                                role: 'assistant',
                                content: [{ type: 'text', text: reply }],
                                timestamp: Date.now()
                            });

                            console.log(`[mock] Reply complete: "${reply}"`);
                        }, 50);
                        return;
                    }

                    const accText = batches[batchIdx];
                    const delta = batchIdx === 0 ? accText : accText.substring(batches[batchIdx - 1].length);

                    // agent event (like real gateway)
                    ws.send(JSON.stringify({
                        type: 'event', event: 'agent',
                        payload: {
                            runId, stream: 'assistant',
                            data: { text: accText, delta },
                            sessionKey, seq: seq, ts: Date.now()
                        }
                    }));

                    // chat delta event (like real gateway)
                    ws.send(JSON.stringify({
                        type: 'event', event: 'chat',
                        payload: {
                            runId, sessionKey, seq: seq,
                            state: 'delta',
                            message: {
                                role: 'assistant',
                                content: [{ type: 'text', text: accText }],
                                timestamp: Date.now()
                            }
                        }
                    }));

                    seq++;
                    batchIdx++;
                    setTimeout(sendNextBatch, 30);
                };

                setTimeout(sendNextBatch, 100);
                break;
            }

            case 'ping':
                ws.send(JSON.stringify({
                    type: 'res', id: data.id, ok: true,
                    payload: { pong: true }
                }));
                break;

            default:
                if (data.id) {
                    ws.send(JSON.stringify({
                        type: 'res', id: data.id, ok: false,
                        error: { code: 'UNKNOWN_METHOD', message: `Unknown: ${data.method}` }
                    }));
                }
        }
    });

    ws.on('close', () => console.log('[mock] Client disconnected'));
});

// Send tick events periodically
setInterval(() => {
    wss.clients.forEach(ws => {
        if (ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({
                type: 'event', event: 'tick',
                payload: { ts: Date.now() }
            }));
        }
    });
}, 30000);

process.on('SIGTERM', () => { wss.close(); process.exit(0); });
process.on('SIGINT', () => { wss.close(); process.exit(0); });
