#!/usr/bin/env node
'use strict';

const http = require('http');

const port = Number(process.argv[2] || 0);
if (!port) throw new Error('port is required');

const server = http.createServer((request, response) => {
  const url = new URL(request.url, `http://127.0.0.1:${port}`);
  if (url.pathname === '/fail') {
    response.writeHead(500, { 'content-type': 'application/json; charset=utf-8' });
    response.end(JSON.stringify({ status: 'error', message: 'forced provider failure' }));
    return;
  }
  const sourceId = String(url.searchParams.get('id') || 'unknown');
  const payload = {
    status: 'success',
    id: sourceId,
    updatedTime: Date.UTC(2026, 6, 27, 1, 0, 0),
    items: [
      {
        id: `https://example.com/${sourceId}/1`,
        title: `${sourceId} 热点一`,
        url: `https://example.com/${sourceId}/1`,
        extra: { hover: `${sourceId} 的公开热点摘要` },
      },
      {
        id: `https://example.com/${sourceId}/2`,
        title: `${sourceId} 热点二`,
        url: `https://example.com/${sourceId}/2`,
        extra: { hover: `${sourceId} 的第二条公开热点摘要` },
      },
    ],
  };
  response.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(payload));
});

server.listen(port, '127.0.0.1');

function stop() {
  server.close(() => process.exit(0));
}

process.on('SIGTERM', stop);
process.on('SIGINT', stop);
