// Tests del logger JSON (DEVOPS-48). Corren sobre el código compilado (dist/),
// con source maps para que la cobertura apunte a src/jsonlog.ts.
const test = require('node:test');
const assert = require('node:assert');
const { EventEmitter } = require('node:events');
const { levelFor, logJson, requestLogger } = require('../dist/jsonlog');

function capturar(fn) {
  const lineas = [];
  const original = console.log;
  console.log = (linea) => lineas.push(JSON.parse(linea));
  try {
    fn();
  } finally {
    console.log = original;
  }
  return lineas;
}

function request(originalUrl, statusCode) {
  const res = new EventEmitter();
  res.statusCode = statusCode;
  let siguiente = false;
  const lineas = capturar(() => {
    requestLogger('svc')({ method: 'GET', originalUrl }, res, () => { siguiente = true; });
    res.emit('finish');
  });
  return { lineas, siguiente };
}

test('levelFor: 5xx ERROR, 4xx WARN, el resto INFO', () => {
  assert.strictEqual(levelFor(200), 'INFO');
  assert.strictEqual(levelFor(302), 'INFO');
  assert.strictEqual(levelFor(404), 'WARN');
  assert.strictEqual(levelFor(503), 'ERROR');
});

test('logJson escribe una línea JSON con los campos comunes', () => {
  const [linea] = capturar(() => logJson('svc', 'INFO', 'listening', { port: 8080 }));
  assert.strictEqual(linea.level, 'INFO');
  assert.strictEqual(linea.msg, 'listening');
  assert.strictEqual(linea.service, 'svc');
  assert.strictEqual(linea.port, 8080);
  assert.ok(!Number.isNaN(Date.parse(linea.time)));
});

test('requestLogger: una línea por request, sin query string', () => {
  const { lineas, siguiente } = request('/api/carts/c1?token=secreto', 404);
  assert.ok(siguiente, 'tiene que llamar a next()');
  assert.strictEqual(lineas.length, 1);
  const [linea] = lineas;
  assert.strictEqual(linea.msg, 'request');
  assert.strictEqual(linea.level, 'WARN');
  assert.strictEqual(linea.method, 'GET');
  assert.strictEqual(linea.path, '/api/carts/c1');
  assert.strictEqual(linea.status, 404);
  assert.strictEqual(typeof linea.duration_ms, 'number');
});

test('requestLogger: /health no se loguea', () => {
  const { lineas, siguiente } = request('/health', 200);
  assert.ok(siguiente);
  assert.deepStrictEqual(lineas, []);
});
