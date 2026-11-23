import { Request, Response, NextFunction } from 'express';

// Logs en JSON (DEVOPS-48): una línea JSON por evento, con el mismo formato en
// los 6 servicios, para consultarlos con CloudWatch Logs Insights.
// Formato y consultas: docs/observabilidad/logs-json.md
// (Este archivo se repite igual en ui, admin y checkout: cada servicio se
// construye por separado. Está excluido de la detección de duplicados.)

export type Level = 'INFO' | 'WARN' | 'ERROR';

export function levelFor(status: number): Level {
  if (status >= 500) return 'ERROR';
  if (status >= 400) return 'WARN';
  return 'INFO';
}

export function logJson(service: string, level: Level, msg: string, fields: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ time: new Date().toISOString(), level, msg, service, ...fields }));
}

// Una línea por request: método, ruta (sin query string), status y duración.
// /health no se loguea: lo llama el ALB cada pocos segundos.
export function requestLogger(service: string) {
  return (req: Request, res: Response, next: NextFunction): void => {
    const start = process.hrtime.bigint();
    res.on('finish', () => {
      // originalUrl: ruta completa aunque el middleware esté montado en un prefijo.
      const path = req.originalUrl.split('?')[0];
      if (path === '/health') return;
      logJson(service, levelFor(res.statusCode), 'request', {
        method: req.method,
        path,
        status: res.statusCode,
        duration_ms: Number(process.hrtime.bigint() - start) / 1e6,
      });
    });
    next();
  };
}
