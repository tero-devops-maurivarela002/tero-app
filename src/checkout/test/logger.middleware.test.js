// Test del middleware HTTP de checkout (DEVOPS-48): delega en el logger JSON común.
require('reflect-metadata');
const test = require('node:test');
const assert = require('node:assert');
const { EventEmitter } = require('node:events');
const { LoggerMiddleware } = require('../dist/middleware/logger.middleware');

test('LoggerMiddleware escribe una línea JSON con service=checkout', () => {
  const res = new EventEmitter();
  res.statusCode = 500;
  const lineas = [];
  const original = console.log;
  console.log = (linea) => lineas.push(JSON.parse(linea));
  let siguiente = false;
  try {
    new LoggerMiddleware().use({ method: 'POST', originalUrl: '/checkout/c1/submit' }, res, () => { siguiente = true; });
    res.emit('finish');
  } finally {
    console.log = original;
  }
  assert.ok(siguiente);
  assert.strictEqual(lineas.length, 1);
  assert.strictEqual(lineas[0].service, 'checkout');
  assert.strictEqual(lineas[0].level, 'ERROR');
  assert.strictEqual(lineas[0].path, '/checkout/c1/submit');
});
